/// Settings destinations whose implementations are available in the mobile shell.
enum BrowserPlatformSettingsDestinationCatalog {
    /// The destinations whose subject exists only on the Mac: the engine
    /// choice, rebindable keyboard commands and WebKit's private feature
    /// registry.
    static let macOnly: Set<BrowserSettingsDestination> = [.engines, .shortcuts, .featureFlags]

    static let cases = BrowserSettingsDestination.all.filter { !macOnly.contains($0) }
}
