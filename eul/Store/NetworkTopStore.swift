//
//  NetworkTopStore.swift
//  eul
//
//  Created by Gao Sun on 2020/10/17.
//  Copyright © 2020 Gao Sun. All rights reserved.
//

import AppKit
import Combine
import SwiftUI

class NetworkTopStore: ObservableObject {
    struct NetworkSpeed: CustomStringConvertible {
        var inSpeedInByte: Double = 0
        var outSpeedInByte: Double = 0
        var inTotalByte: Double = 0
        var outTotalByte: Double = 0

        var totalSpeedInByte: Double {
            inSpeedInByte + outSpeedInByte
        }

        var totalByte: Double {
            inTotalByte + outTotalByte
        }

        var description: String {
            fatalError("not implemented")
        }
    }

    struct ProcessNetworkUsage: ProcessUsage {
        typealias T = NetworkSpeed
        let pid: Int
        let command: String
        let value: NetworkSpeed
        let runningApp: NSRunningApplication?
    }

    private var timer: Timer?
    private var activeCancellable: AnyCancellable?
    private var lastTimestamp: TimeInterval = Date().timeIntervalSince1970
    private var lastInBytes: [Int: Double] = [:]
    private var lastOutBytes: [Int: Double] = [:]
    private var isWaitingForNettopOutput = false // main thread only
    @ObservedObject var preferenceStore = SharedStore.preference
    @Published var processes: [ProcessNetworkUsage] = []

    private var interval: Int {
        preferenceStore.networkRefreshRate
    }

    var totalSpeed: NetworkSpeed {
        processes.reduce(into: NetworkSpeed()) { result, usage in
            result.inSpeedInByte += usage.value.inSpeedInByte
            result.outSpeedInByte += usage.value.outSpeedInByte
        }
    }

    private func run() {
        // nettop takes about 5 s, longer than the refresh interval; skip ticks while one is running.
        guard !isWaitingForNettopOutput else { return }
        isWaitingForNettopOutput = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let nettopOutput = shell("nettop -L 1 -P -x -J bytes_in,bytes_out 2>/dev/null")
            DispatchQueue.main.async {
                self?.isWaitingForNettopOutput = false
                self?.updateProcesses(fromNettopOutput: nettopOutput)
            }
        }
    }

    private func updateProcesses(fromNettopOutput nettopOutput: String?) {
        // lastInBytes, lastOutBytes and lastTimestamp are also reset in update(shouldStart:); touch them only on main.
        dispatchPrecondition(condition: .onQueue(.main))
        guard let string = nettopOutput else {
            print("unable to fetch network activity, please make sure nettop is available")
            return
        }

        let rows = string.split(separator: "\n").map { String($0) }
        let headers = rows[0]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0.lowercased()) }
        let processIndex = 0

        guard
            let inBytesIndex = headers.firstIndex(of: "bytes_in"),
            let outBytesIndex = headers.firstIndex(of: "bytes_out")
        else {
            return
        }

        let runningApps = NSWorkspace.shared.runningApplications
        let time = Date().timeIntervalSince1970
        let timeElapsed = time - lastTimestamp
        lastTimestamp = time

        Print("network top is updating")
        let updated = rows.dropFirst().compactMap { row -> ProcessNetworkUsage? in
            let cols = row.split(separator: ",").map { String($0) }

            guard
                cols.indices.contains(processIndex),
                cols.indices.contains(inBytesIndex),
                cols.indices.contains(outBytesIndex)
            else {
                return nil
            }

            let processCol = cols[processIndex]
            let splitted = processCol.split(separator: ".").map { String($0) }

            guard
                let last = splitted.last,
                let pid = Int(last),
                let inBytes = Double(cols[inBytesIndex]),
                let outBytes = Double(cols[outBytesIndex])
            else {
                return nil
            }

            let totalBytes = inBytes + outBytes

            guard totalBytes > 0 else {
                return nil
            }

            let lastIn = lastInBytes[pid]
            let lastOut = lastOutBytes[pid]

            lastInBytes[pid] = inBytes
            lastOutBytes[pid] = outBytes

            let speed = NetworkSpeed(
                inSpeedInByte: lastIn.map { $0 > inBytes ? 0 : (inBytes - $0) / timeElapsed } ?? 0,
                outSpeedInByte: lastOut.map { $0 > outBytes ? 0 : (outBytes - $0) / timeElapsed } ?? 0,
                inTotalByte: inBytes,
                outTotalByte: outBytes
            )

            return ProcessNetworkUsage(
                pid: pid,
                command: splitted[0],
                value: speed,
                runningApp: runningApps.first(where: { $0.processIdentifier == pid })
            )
        }
        .sorted(by: { $0.value.totalByte > $1.value.totalByte })

        processes = updated
    }

    func update(shouldStart: Bool) {
        guard shouldStart else {
            timer?.invalidate()
            timer = nil
            return
        }

        if timer != nil {
            Print("network task already started")
            return
        }

        lastInBytes.removeAll()
        lastOutBytes.removeAll()
        lastTimestamp = Date().timeIntervalSince1970
        processes = []

        let timer = Timer.scheduledTimer(withTimeInterval: Double(interval), repeats: true) { [weak self] _ in
            self?.run()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    init() {
        activeCancellable = Publishers
            .CombineLatest3(
                preferenceStore.$showNetworkTopActivities,
                SharedStore.menuComponents.$activeComponents,
                SharedStore.ui.$menuOpened
            )
            .map {
                $0 && $1.contains(.Network) && $2
            }
            .sink { [self] in
                update(shouldStart: $0)
            }
    }
}
