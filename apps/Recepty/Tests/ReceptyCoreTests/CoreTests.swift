import XCTest
@testable import ReceptyCore

final class CoreTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(Importer.minutes("PT1H30M"), 90)
        XCTAssertEqual(Importer.minutes("P0DT0H45M"), 45)
        XCTAssertNil(Importer.minutes("abc"))
    }

    func testSchemaRecipe() {
        let html = """
        <html><script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"WebPage"},
        {"@type":"Recipe","name":"Palacinky","recipeYield":"4 porcie","prepTime":"PT10M","cookTime":"PT20M",
        "recipeIngredient":["250 g hladkej múky","2 vajcia","500 ml mlieka"],
        "recipeInstructions":[{"@type":"HowToStep","text":"Zmiešame múku s mliekom."},{"@type":"HowToStep","text":"Pečieme 2 minúty z každej strany."}]}]}</script></html>
        """
        let d = Importer.schemaRecipe(html)
        XCTAssertNotNil(d)
        let r = Importer.recipe(fromSchema: d!)
        XCTAssertEqual(r.title, "Palacinky")
        XCTAssertEqual(r.servings, 4)
        XCTAssertEqual(r.ingredients.count, 3)
        XCTAssertEqual(r.steps.count, 2)
        XCTAssertEqual(r.prepMin, 10)
        XCTAssertTrue(Importer.looksSlovak(r))
        XCTAssertEqual(r.steps[1].timers.first?.seconds, 120)
    }

    func testEntities() {
        XCTAssertEqual(Importer.decodeEntities("a &amp; b &#269;&#x161;"), "a & b čš")
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.qty(0.5), "½")
        XCTAssertEqual(Fmt.qty(1.25), "1¼")
        XCTAssertEqual(Fmt.qty(12.4), "12")
        XCTAssertEqual(Fmt.grams(123), "125 g")
        XCTAssertEqual("Varíme 10–15 minút".timers.first?.seconds, 900)
    }

    func testIngredientsText() {
        let ings = Recipe.ingredients(fromText: "# Cesto\n250 g múky\n- 2 vajcia\nPlnka:\n200 g tvarohu")
        XCTAssertEqual(ings.map(\.section), ["Cesto", "Cesto", "Plnka"])
        XCTAssertEqual(ings[1].line, "2 vajcia")
        var r = Recipe(title: "x"); r.ingredients = ings
        XCTAssertEqual(Recipe.ingredients(fromText: r.ingredientsText).map(\.line), ings.map(\.line))
    }

    func testNutritionAndLog() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("recepty-test-\(UUID()).sqlite").path
        let store = try Store(path: path)
        var r = Recipe(title: "Test"); r.servings = 2
        var a = Ingredient(line: "200 g múky"); a.grams = 200; a.per100 = Nutrients(kcal: 350, protein: 10); a.status = .matched
        var b = Ingredient(line: "voda"); b.status = .skipped
        r.ingredients = [a, b]
        r = try store.save(r)
        XCTAssertEqual(r.total.kcal, 700)
        XCTAssertEqual(r.perServing.kcal, 350)
        XCTAssertEqual(r.dishGrams, 200)
        let m = try store.logMeal(recipe: r, grams: 50)
        XCTAssertEqual(m.nutrients.kcal, 175, accuracy: 0.01)
        XCTAssertEqual(store.recipe(r.id)?.cookedCount, 1)
        XCTAssertEqual(try store.findRecipe("tes").id, r.id)
        let shop = Shopping.list([(r, 4)])
        XCTAssertEqual(shop.first?.grams, 400)
    }

    func testAuthorAndPhotos() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("recepty-test-\(UUID()).sqlite").path
        let store = try Store(path: path)
        let img = FileManager.default.temporaryDirectory.appendingPathComponent("recepty-test-\(UUID()).jpg")
        try Data(repeating: 1, count: 10).write(to: img)
        var r = Recipe(title: "Linecké"); r.author = "babka Mária"
        r.photos = [SourcePhoto(path: img.path, text: "28 dkg múky")]
        r = try store.save(r)
        XCTAssertEqual(r.author, "babka Mária")
        XCTAssertEqual(r.photos.count, 1)
        XCTAssertTrue(r.photos[0].path.hasPrefix(Store.photosDir.path))
        XCTAssertEqual(r.coverPath, r.photos[0].path)
        r = try store.save(r)   // saving again doesn't copy the photo twice
        XCTAssertEqual(r.photos.count, 1)
        XCTAssertEqual(store.allAuthors(), ["babka Mária"])
        try store.delete(recipe: r.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.photos[0].path))
    }

    func testFoodSearch() throws {
        let db = try XCTUnwrap(FoodDB.shared)
        let eggs = db.search("egg whole raw")
        XCTAssertFalse(eggs.isEmpty)
        XCTAssertTrue(eggs[0].name.lowercased().contains("egg"))
        XCTAssertNotNil(db.food(eggs[0].id))
    }
}
