import Foundation

/// The household's Supabase project. The publishable key is meant to ship in apps: row-level security limits every query
/// to the signed-in member's household.
public enum Config {
    public static let supabaseURL = URL(string: "https://YOUR-PROJECT-REF.supabase.co")!
    public static let supabaseKey = "YOUR-SUPABASE-PUBLISHABLE-KEY"
    /// Where sign-in links from the e-mail land (allowed in the project's auth settings).
    public static let authRedirect = "home://auth"
}
