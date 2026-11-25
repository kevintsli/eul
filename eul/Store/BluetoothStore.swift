//
//  BluetoothStore.swift
//  eul
//
//  Created by Gao Sun on 2021/1/18.
//  Copyright © 2021 Gao Sun. All rights reserved.
//

import Foundation

class BluetoothStore: ObservableObject {
    @Published var devices: [BluetoothDevice] = []

    func fetch() {
        // system_profiler can take a while with many paired devices; keep it off the main thread.
        DispatchQueue.global(qos: .utility).async { [self] in
            let connectedDevices = Self.readConnectedDevices()
            DispatchQueue.main.async { [self] in
                devices = connectedDevices
            }
        }
    }

    private static func readConnectedDevices() -> [BluetoothDevice] {
        guard let data = shellData(["system_profiler SPBluetoothDataType -json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let btArray = json["SPBluetoothDataType"] as? [[String: Any]],
              let first = btArray.first,
              let connected = first["device_connected"] as? [[String: Any]]
        else { return [] }

        return connected.compactMap { dict -> BluetoothDevice? in
            // [String: Any] so one non-string value does not drop the whole device.
            guard let entry = dict.first,
                  let props = entry.value as? [String: Any],
                  let address = props["device_address"] as? String
            else { return nil }

            return BluetoothDevice(
                name: entry.key,
                address: address,
                batteryLevel: props["device_batteryLevelMain"] as? String,
                batteryLevelLeft: props["device_batteryLevelLeft"] as? String,
                batteryLevelRight: props["device_batteryLevelRight"] as? String,
                batteryLevelCase: props["device_batteryLevelCase"] as? String
            )
        }
    }
}
