#if canImport(Darwin)
    import DualControlCore
    import Foundation
    import IOKit
    import IOKit.serial

    /// The serial ports IOKit knows, read from the registry. Never opens a port.
    public enum SerialPortList {
        /// Every listed port (`/dev/cu.*` only, see `SerialPorts.isListed`), sorted by path, with serial numbers
        /// that two connected devices share marked.
        public static func ports() -> [SerialPortInfo] {
            guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                return []
            }
            defer { IOObjectRelease(iterator) }
            var found: [SerialPortInfo] = []
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let path = property(service, kIOCalloutDeviceKey, searchParents: false) as? String,
                    SerialPorts.isListed(path)
                else { continue }
                var device: SerialDevice?
                if let vendor = property(service, "idVendor") as? Int,
                    let product = property(service, "idProduct") as? Int
                {
                    device = SerialDevice(
                        vendorID: vendor,
                        productID: product,
                        serialNumber: property(service, "USB Serial Number") as? String
                            ?? property(service, "kUSBSerialNumberString") as? String,
                        locationID: property(service, "locationID") as? Int
                    )
                }
                found.append(
                    SerialPortInfo(
                        path: path,
                        device: device,
                        product: property(service, "USB Product Name") as? String
                            ?? property(service, "kUSBProductString") as? String,
                        manufacturer: property(service, "USB Vendor Name") as? String
                            ?? property(service, "kUSBVendorString") as? String
                    )
                )
            }
            return SerialPorts.markingSharedSerialNumbers(found.sorted { $0.path < $1.path })
        }

        /// The listed port at `path`, if it is plugged in now.
        public static func lookUp(_ path: String) -> SerialPortInfo? {
            guard SerialPorts.isListed(path) else { return nil }
            return ports().first { $0.path == path }
        }

        /// A property of `service`, or of the nearest parent that has it (the USB device sits a few levels up).
        private static func property(_ service: io_object_t, _ key: String, searchParents: Bool = true) -> Any? {
            if !searchParents {
                return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue()
            }
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            return IORegistryEntrySearchCFProperty(
                service,
                kIOServicePlane,
                key as CFString,
                kCFAllocatorDefault,
                options
            )
        }
    }
#endif
