// brain-apple: Apple Photos (PhotoKit, Vision text recognition) and Apple Maps (MapKit) for Brain.
// Launched as an app (open -a "Brain Apple.app" --args ... --out file) so macOS asks for Photos access for it once.
//   brain-apple albums
//   brain-apple photos [--from ISO] [--to ISO] [--album name|id] [--place text | --near lat,lon] [--radius km]
//                      [--kind photo|video|screenshot|live|any] [--favorites] [--text query] [--scan N] [--limit N]
//   brain-apple export --ids id,id --dir path [--size original|large]
//   brain-apple album-add --ids id,id --album name           (creates the album when missing)
//   brain-apple geocode --q text
//   brain-apple eta --from text --to text [--mode car|walk|transit] [--depart ISO | --arrive ISO]
// Output: {"result": ...} or {"error": "..."} in --out (or stdout).
import AppKit
import CoreLocation
import Foundation
import MapKit
import Photos
import Vision

let args = CommandLine.arguments
func opt(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let outFile = opt("--out")

func write(_ v: Any) {
    let d = (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])) ?? Data("{\"error\":\"bad output\"}".utf8)
    if let f = outFile { try? d.write(to: URL(fileURLWithPath: f), options: .atomic) } else { FileHandle.standardOutput.write(d + Data("\n".utf8)) }
}
func die(_ msg: String, _ code: Int32 = 1) -> Never { write(["error": msg]); exit(code) }
func done(_ v: Any) -> Never { write(["result": v]); exit(0) }

let isoLocal: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f }()
let dayOnly: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
func parseDate(_ s: String?, endOfDay: Bool = false) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    if let d = ISO8601DateFormatter().date(from: s) { return d }
    if let d = isoLocal.date(from: s.count == 16 ? s + ":00" : String(s.prefix(19))) { return d }
    if let d = dayOnly.date(from: String(s.prefix(10))) { return endOfDay ? d.addingTimeInterval(86399) : d }
    return nil
}
func local(_ d: Date) -> String { isoLocal.string(from: d) }
func ids() -> [String] { (opt("--ids") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

// MARK: Photos

func photosAccess() {
    let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if s == .authorized || s == .limited { return }
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in granted = st == .authorized || st == .limited; sem.signal() }
    sem.wait()
    if !granted { die("no Photos access: allow Brain Apple in System Settings → Privacy & Security → Photos", 3) }
}

func kind(_ a: PHAsset) -> String {
    if a.mediaType == .video { return "video" }
    if a.mediaSubtypes.contains(.photoScreenshot) { return "screenshot" }
    if a.mediaSubtypes.contains(.photoLive) { return "live" }
    return "photo"
}

func fileName(_ a: PHAsset) -> String? { PHAssetResource.assetResources(for: a).first?.originalFilename }

func collection(_ name: String) -> PHAssetCollection? {
    if let c = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [name], options: nil).firstObject { return c }
    for type in [PHAssetCollectionType.album, .smartAlbum] {
        var found: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil).enumerateObjects { c, _, stop in
            if c.localizedTitle?.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { found = c; stop.pointee = true }
        }
        if let found { return found }
    }
    return nil
}

/// Text in a picture, cached by asset and its modification date (recognition is the slow part).
let cacheURL: URL = {
    let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.brain.brain-apple")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent("ocr.json")
}()
var ocrCache: [String: [String: Any]] = (try? JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: [String: Any]]) ?? [:]
var ocrDirty = false

func image(_ a: PHAsset, side: CGFloat, network: Bool = true) -> CGImage? {
    let o = PHImageRequestOptions()
    o.isSynchronous = true; o.deliveryMode = .highQualityFormat; o.isNetworkAccessAllowed = network; o.resizeMode = .fast
    var img: NSImage?
    PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: o) { i, _ in img = i }
    return img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

/// nil when the picture is only in iCloud and `network` is off (downloading is what makes a text search slow).
func text(_ a: PHAsset, fast: Bool, network: Bool) -> String? {
    let stamp = (a.modificationDate ?? a.creationDate ?? .distantPast).timeIntervalSince1970
    if let c = ocrCache[a.localIdentifier], c["m"] as? Double == stamp, let t = c["t"] as? String { return t }
    guard let cg = image(a, side: 1400, network: false) ?? (network ? image(a, side: 1400) : nil) else { return nil }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = fast ? .fast : .accurate
    req.usesLanguageCorrection = !fast
    req.automaticallyDetectsLanguage = true
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    let t = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    ocrCache[a.localIdentifier] = ["m": stamp, "t": t]
    ocrDirty = true
    return t
}

func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

func snippet(_ t: String, _ q: String) -> String? {
    let ft = fold(t), words = fold(q).split(separator: " ").map(String.init)
    guard !words.isEmpty, words.allSatisfy({ ft.contains($0) }), let r = ft.range(of: words[0]) else { return nil }
    let i = ft.distance(from: ft.startIndex, to: r.lowerBound)
    let chars = Array(t.replacingOccurrences(of: "\n", with: " ")), from = max(0, i - 60), to = min(chars.count, i + 100)
    return (from > 0 ? "…" : "") + String(chars[from..<to]) + (to < chars.count ? "…" : "")
}

func row(_ a: PHAsset) -> [String: Any] {
    var o: [String: Any] = ["id": a.localIdentifier, "kind": kind(a), "width": a.pixelWidth, "height": a.pixelHeight]
    if let d = a.creationDate { o["date"] = local(d) }
    if a.isFavorite { o["favorite"] = true }
    if a.mediaType == .video { o["seconds"] = Int(a.duration.rounded()) }
    if let l = a.location { o["lat"] = (l.coordinate.latitude * 1e4).rounded() / 1e4; o["lon"] = (l.coordinate.longitude * 1e4).rounded() / 1e4 }
    if let f = fileName(a) { o["file"] = f }
    return o
}

func rawSearch(_ q: String, near: CLLocationCoordinate2D?, poi: Bool) async -> [MKMapItem] {
    let r = MKLocalSearch.Request()
    r.naturalLanguageQuery = q
    r.resultTypes = poi ? .pointOfInterest : [.address, .pointOfInterest]
    if let near { r.region = MKCoordinateRegion(center: near, latitudinalMeters: 60000, longitudinalMeters: 60000) }
    return (try? await MKLocalSearch(request: r).start().mapItems) ?? []
}

/// Places for a query. Without a region Maps returns mostly streets and towns, so the search runs again around the first
/// hit looking for a place of interest whose name matches ("Nová Tržnica, Bratislava" is the market hall, not Nová street).
func search(_ q: String, near: CLLocationCoordinate2D? = nil) async -> [MKMapItem] {
    let first = await rawSearch(q, near: near, poi: false)
    // a house number means an address: keep Maps' own answer
    if q.rangeOfCharacter(from: .decimalDigits) != nil, !first.isEmpty { return first }
    guard let anchor = near ?? first.first?.location.coordinate else { return first }
    let words = Set(fold(q).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
    let pois = await rawSearch(q, near: anchor, poi: true)
    func score(_ i: MKMapItem) -> Int { words.filter { fold(i.name ?? "").contains($0) }.count }
    let best = pois.filter { score($0) > 0 }.sorted { score($0) > score($1) }
    if let b = best.first, score(b) >= (first.first.map(score) ?? 0) { return [b] + first }
    return first.isEmpty ? pois : first
}

func place(_ i: MKMapItem) -> [String: Any] {
    let c = i.location.coordinate
    var o: [String: Any] = ["name": i.name ?? "", "lat": (c.latitude * 1e5).rounded() / 1e5, "lon": (c.longitude * 1e5).rounded() / 1e5]
    if let a = i.address?.fullAddress ?? i.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true) { o["address"] = a }
    return o
}

func photos() async -> Never {
    photosAccess()
    let o = PHFetchOptions()
    o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    var preds: [NSPredicate] = []
    if let f = parseDate(opt("--from")) { preds.append(NSPredicate(format: "creationDate >= %@", f as NSDate)) }
    if let t = parseDate(opt("--to"), endOfDay: true) { preds.append(NSPredicate(format: "creationDate <= %@", t as NSDate)) }
    if args.contains("--favorites") { preds.append(NSPredicate(format: "isFavorite == YES")) }
    switch opt("--kind") ?? "any" {
    case "video": preds.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
    case "photo", "live": preds.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
    case "screenshot": preds.append(NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue))
    default: break
    }
    if !preds.isEmpty { o.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: preds) }
    let fetch: PHFetchResult<PHAsset>
    if let name = opt("--album") {
        guard let c = collection(name) else { die("no album \"\(name)\" (albums lists them)") }
        fetch = PHAsset.fetchAssets(in: c, options: o)
    } else { fetch = PHAsset.fetchAssets(with: o) }

    var center: CLLocationCoordinate2D?, placeInfo: [String: Any]?
    if let n = opt("--near") {
        let p = n.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if p.count == 2 { center = CLLocationCoordinate2D(latitude: p[0], longitude: p[1]) }
    } else if let q = opt("--place") {
        guard let i = await search(q).first else { die("Mapy nepoznajú miesto \"\(q)\"") }
        center = i.location.coordinate; placeInfo = place(i)
    }
    let radius = (Double(opt("--radius") ?? "") ?? 3) * 1000
    let wantKind = opt("--kind"), query = opt("--text"), limit = Int(opt("--limit") ?? "") ?? 40
    let scanMax = Int(opt("--scan") ?? "") ?? 400
    var out: [[String: Any]] = [], scanned = 0, matched = 0, skipped = 0, timedOut = false
    let fast = fetch.count > 120, network = scanMax <= 60, deadline = Date().addingTimeInterval(Double(opt("--budget") ?? "") ?? 80)
    func saveCache() { if ocrDirty, let d = try? JSONSerialization.data(withJSONObject: ocrCache) { try? d.write(to: cacheURL, options: .atomic); ocrDirty = false } }
    fetch.enumerateObjects { a, _, stop in
        if wantKind == "live", kind(a) != "live" { return }
        if wantKind == "photo", kind(a) != "photo" { return }
        if let center {
            guard let l = a.location, l.distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude)) <= radius else { return }
        }
        var r = row(a)
        if let query {
            if scanned >= scanMax { stop.pointee = true; return }
            if Date() > deadline { timedOut = true; stop.pointee = true; return }
            scanned += 1
            if scanned % 25 == 0 { saveCache() }
            guard let t = text(a, fast: fast, network: network) else { skipped += 1; return }
            guard let s = snippet(t, query) else { return }
            r["text"] = s
        }
        matched += 1
        if out.count < limit { out.append(r) } else if query == nil { stop.pointee = true }
    }
    saveCache()
    var res: [String: Any] = ["photos": out, "shown": out.count]
    if query != nil {
        res["scanned"] = scanned; res["matched"] = matched
        if skipped > 0 { res["only_in_icloud"] = skipped }
        if timedOut { res["note"] = "Čas vypršal po \(scanned) obrázkoch (ďalšie hľadanie pokračuje rýchlejšie, prečítané si pamätám). Zúž dátum, album alebo druh." }
        else if scanned >= scanMax { res["note"] = "Prehľadaných len \(scanMax) najnovších: zúž dátum, album alebo druh (screenshot)." }
        if skipped > 0 { res["icloud_note"] = "\(skipped) obrázkov je len v iCloude; pri menšom výbere (scan ≤ 60) ich stiahnem a prečítam tiež." }
    }
    if let placeInfo { res["place"] = placeInfo; res["radius_km"] = radius / 1000 }
    done(res)
}

func albums() -> Never {
    photosAccess()
    var out: [[String: Any]] = []
    let add = { (c: PHAssetCollection, smart: Bool) in
        let n = PHAsset.fetchAssets(in: c, options: nil).count
        if n > 0 || !smart { out.append(["id": c.localIdentifier, "title": c.localizedTitle ?? "", "count": n, "smart": smart]) }
    }
    PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, _ in add(c, false) }
    for s: PHAssetCollectionSubtype in [.smartAlbumFavorites, .smartAlbumScreenshots, .smartAlbumSelfPortraits, .smartAlbumVideos, .smartAlbumPanoramas, .smartAlbumLivePhotos] {
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: s, options: nil).enumerateObjects { c, _, _ in add(c, true) }
    }
    done(out)
}

func assets(_ list: [String]) -> [PHAsset] {
    var r: [PHAsset] = []
    PHAsset.fetchAssets(withLocalIdentifiers: list, options: nil).enumerateObjects { a, _, _ in r.append(a) }
    if r.isEmpty { die("no photos with these ids (ids come from photos_search)") }
    return r
}

func export() async -> Never {
    photosAccess()
    guard let dir = opt("--dir") else { die("--dir is required", 2) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let large = opt("--size") == "large"
    var files: [String] = [], failed: [String] = []
    func free(_ name: String) -> String {
        var p = (dir as NSString).appendingPathComponent(name), n = 1
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: p) { n += 1; p = (dir as NSString).appendingPathComponent("\(base) \(n).\(ext)") }
        return p
    }
    for a in assets(ids()) {
        let name = fileName(a) ?? "foto.jpg"
        if large && a.mediaType == .image {
            guard let cg = image(a, side: 2048) else { failed.append(name); continue }
            let p = free((name as NSString).deletingPathExtension + ".jpg")
            let rep = NSBitmapImageRep(cgImage: cg)
            if let d = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]), (try? d.write(to: URL(fileURLWithPath: p))) != nil { files.append(p) } else { failed.append(name) }
            continue
        }
        let res = PHAssetResource.assetResources(for: a)
        guard let r = res.first(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }) ?? res.first(where: { $0.type == .photo || $0.type == .video }) else { failed.append(name); continue }
        let p = free(r.originalFilename)
        let o = PHAssetResourceRequestOptions(); o.isNetworkAccessAllowed = true
        do { try await PHAssetResourceManager.default().writeData(for: r, toFile: URL(fileURLWithPath: p), options: o); files.append(p) }
        catch { failed.append("\(name): \(error.localizedDescription)") }
    }
    done(["files": files, "failed": failed])
}

func albumAdd() async -> Never {
    photosAccess()
    guard let name = opt("--album"), !name.isEmpty else { die("--album is required", 2) }
    let list = assets(ids())
    let existing = collection(name)
    if let existing, existing.assetCollectionType == .smartAlbum { die("\"\(name)\" is a smart album, photos can't be added to it") }
    do {
        try await PHPhotoLibrary.shared().performChanges {
            let req = existing.flatMap { PHAssetCollectionChangeRequest(for: $0) } ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            req.addAssets(list as NSArray)
        }
    } catch { die("Photos refused: \(error.localizedDescription)") }
    done(["album": name, "added": list.count, "created": existing == nil])
}

// MARK: Maps

func geocode() async -> Never {
    guard let q = opt("--q") else { die("--q is required", 2) }
    let r = await search(q)
    if r.isEmpty { die("Mapy nepoznajú \"\(q)\"") }
    done(r.prefix(3).map(place))
}

func eta() async -> Never {
    guard let fromQ = opt("--from"), let toQ = opt("--to") else { die("--from and --to are required", 2) }
    guard let from = await search(fromQ).first else { die("Mapy nepoznajú východisko \"\(fromQ)\"") }
    guard let to = await search(toQ, near: from.location.coordinate).first else { die("Mapy nepoznajú cieľ \"\(toQ)\"") }
    let r = MKDirections.Request()
    r.source = from; r.destination = to
    let mode = opt("--mode") ?? "car"
    r.transportType = mode == "walk" ? .walking : mode == "transit" ? .transit : .automobile
    if let d = parseDate(opt("--arrive")) { r.arrivalDate = d } else if let d = parseDate(opt("--depart")) { r.departureDate = d }
    do {
        let e = try await MKDirections(request: r).calculateETA()
        done(["from": place(from), "to": place(to), "mode": mode, "minutes": Int((e.expectedTravelTime / 60).rounded()),
              "km": (e.distance / 100).rounded() / 10, "depart": local(e.expectedDepartureDate), "arrive": local(e.expectedArrivalDate)])
    } catch {
        die(mode == "transit" ? "Apple Mapy nemajú pre túto trasu MHD (\(error.localizedDescription)); skús car alebo walk."
                              : "Mapy trasu nenašli: \(error.localizedDescription)")
    }
}

@main
struct BrainApple {
    static func main() async {
        switch args.count > 1 ? args[1] : "" {
        case "albums": albums()
        case "photos": await photos()
        case "export": await export()
        case "album-add": await albumAdd()
        case "geocode": await geocode()
        case "eta": await eta()
        default: die("unknown command (albums, photos, export, album-add, geocode, eta)", 2)
        }
    }
}
