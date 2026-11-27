import AppKit
import CoreGraphics

final class DisplayMenu: NSObject, NSMenuDelegate {
    private typealias Configure = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
    private let configure: Configure? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSConfigureDisplayEnabled").map {
        unsafeBitCast($0, to: Configure.self)
    }
    // WindowServer cannot resolve the UUID while a display is disabled.
    // Numeric IDs are reusable after reboot, so scope recovery records to this boot.
    private let storageKey: String? = {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = buffer.count
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &count, nil, 0) == 0 else { return nil }
        return "DisabledExternalDisplays." + String(cString: buffer)
    }()
    private struct Display: Codable {
        let name: String
        let id: CGDirectDisplayID
    }
    private var remembered: [String: Display] {
        get {
            guard let storageKey, let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
            return (try? PropertyListDecoder().decode([String: Display].self, from: data)) ?? [:]
        }
        set {
            guard let storageKey else { return }
            UserDefaults.standard.set(try? PropertyListEncoder().encode(newValue), forKey: storageKey)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        var disabled = remembered
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            guard CGDisplayIsBuiltin(id) == 0, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { continue }
            let key = CFUUIDCreateString(nil, uuid) as String
            disabled.removeValue(forKey: key)
            add(to: menu, name: screen.localizedName, key: key, enable: false, available: NSScreen.screens.count > 1)
        }
        if disabled.count != remembered.count { remembered = disabled }
        for (key, display) in disabled.sorted(by: { $0.key < $1.key }) {
            add(to: menu, name: display.name, key: key, enable: true, available: true)
        }
        if menu.items.isEmpty {
            menu.addItem(withTitle: "Sin monitores externos", action: nil, keyEquivalent: "").isEnabled = false
        }
    }

    private func add(to menu: NSMenu, name: String, key: String, enable: Bool, available: Bool) {
        let verb = enable ? "Reactivar" : "Desactivar"
        let item = menu.addItem(withTitle: "\(verb) \(name)", action: #selector(toggle(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.tag = enable ? 1 : 0
        item.isEnabled = available && configure != nil && storageKey != nil
    }

    @objc private func toggle(_ item: NSMenuItem) {
        guard let configure, let key = item.representedObject as? String,
              let uuid = CFUUIDCreateFromString(nil, key as CFString) else { return }
        let enable = item.tag == 1
        let resolved = CGDisplayGetDisplayIDFromUUID(uuid)
        let id = enable && resolved == 0 ? remembered[key]?.id ?? 0 : resolved
        if let current = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(), !CFEqual(current, uuid) { fail(); return }
        guard id != kCGNullDirectDisplay, CGDisplayIsBuiltin(id) == 0 else { fail(); return }
        if !enable {
            guard CGDisplayIsActive(id) != 0, NSScreen.screens.contains(where: { screen in
                guard let other = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
                return other.uint32Value != id && CGDisplayIsActive(other.uint32Value) != 0
            }) else { return }
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { fail(); return }
        guard configure(config, id, enable) == .success else { CGCancelDisplayConfiguration(config); fail(); return }
        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else { fail(); return }
        if !enable { remembered[key] = Display(name: String(item.title.dropFirst("Desactivar ".count)), id: id) }
        if (CGDisplayIsActive(id) != 0) != enable { fail() }
        else if enable { remembered.removeValue(forKey: key) }
    }

    private func fail() {
        let alert = NSAlert()
        alert.messageText = "No se pudo cambiar el estado del monitor"
        alert.informativeText = "Comprobá que el monitor esté conectado y encendido."
        alert.runModal()
    }
}
