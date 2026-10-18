import Foundation

/// Which gateway address iPhone Remote Controller dials first.
///
/// On site Wi‑Fi the LAN address is the short path. Off that Wi‑Fi, including cellular,
/// the LAN address does not reach the gateway. Trying it first burns the request timeout
/// and the overlay attempt never shows up in the gateway log.
public enum RemotePathOrder {
    /// The phone's Wi‑Fi address is in the same /24 as the paired LAN host.
    public static func onSiteWiFi(lanHost: String?, wifiIPv4: String?) -> Bool {
        guard let lan = ipv4(lanHost), let wifi = ipv4(wifiIPv4) else { return false }
        return (lan & 0xffff_ff00) == (wifi & 0xffff_ff00)
    }

    /// Overlay first when the phone is not on site Wi‑Fi. A connection the app still calls
    /// "connected" stays first only when that path is still the right network.
    public static func order(lanURL: String?, overlayURL: String?, connectedURL: String?, onSiteWiFi: Bool) -> [String] {
        var urls: [String] = []
        if onSiteWiFi {
            append(lanURL, to: &urls)
            append(overlayURL, to: &urls)
        } else {
            append(overlayURL, to: &urls)
            append(lanURL, to: &urls)
        }
        guard let connectedURL, urls.contains(connectedURL) else { return urls }
        let connectedIsLAN = connectedURL == lanURL
        if !onSiteWiFi && connectedIsLAN { return urls }
        urls.removeAll { $0 == connectedURL }
        urls.insert(connectedURL, at: 0)
        return urls
    }

    private static func append(_ url: String?, to urls: inout [String]) {
        guard let url, !url.isEmpty, !urls.contains(url) else { return }
        urls.append(url)
    }

    private static func ipv4(_ text: String?) -> UInt32? {
        guard let text else { return nil }
        let host = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard part.allSatisfy(\.isNumber), let byte = UInt32(part), byte < 256 else { return nil }
            if part.count > 1, part.first == "0" { return nil }
            value = (value << 8) | byte
        }
        return value
    }
}
