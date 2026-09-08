//
//  NotchTabsSettings.swift
//  boringNotch
//
//  Which tabs exist, and where the homelab lives.
//

import Defaults
import SwiftUI

struct NotchTabsSettings: View {
    @Default(.notchPanelFlipInterval) var flipInterval
    @Default(.homelabPrometheusURL) var prometheusURL
    @Default(.homelabLokiURL) var lokiURL
    @Default(.homelabQbitURL) var qbitURL
    @Default(.homelabNASHost) var nasHost
    @Default(.homelabQbitUsername) var qbitUsername
    @Default(.homelabQbitPassword) var qbitPassword

    /// The tabs this pane governs. Home and shelf are upstream's and are not switchable here.
    private var forkTabs: [NotchViews] { [.claude, .network, .system, .homelab] }

    var body: some View {
        Form {
            Section {
                ForEach(forkTabs, id: \.self) { tab in
                    Defaults.Toggle(key: tab.enabledKey) {
                        Label(tab.title, systemImage: tab.icon)
                    }
                }
            } header: {
                Text("Tabs")
            } footer: {
                Text("Each tab holds several panels that flip like a departure board. Click a tab you are already on to step through its panels by hand, or hover to hold one still while you read it.")
                    .font(.footnote)
            }

            Section {
                HStack {
                    Text("Seconds per panel")
                    Spacer()
                    Text(String(format: "%.0f", flipInterval))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $flipInterval, in: 3...20, step: 1)
            } footer: {
                Text("Only the panel on screen samples anything, so a slower flip is also less work. A closed notch samples nothing at all.")
                    .font(.footnote)
            }

            Section {
                TextField("http://192.168.1.73:9090", text: $prometheusURL)
                    .textFieldStyle(.roundedBorder)
                TextField("http://192.168.1.73:3100", text: $lokiURL)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Homelab")
                HStack {
                    Text("NAS host label")
                    Spacer()
                    TextField("synology", text: $nasHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            } footer: {
                Text("Prometheus and Loki, used by the Homelab tab. Prometheus supplies metrics for hosts running node_exporter; Loki supplies logs and liveness for everything that ships them, which is how hosts without an exporter still show up. The NAS host label must match the value your NAS logs under — whatever you set as its Promtail host label. Leave the URLs blank to keep the Homelab panels empty.")
                    .font(.footnote)
            }

            Section {
                TextField("http://192.168.1.75:8080", text: $qbitURL)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Username")
                    Spacer()
                    TextField("admin", text: $qbitUsername)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
                HStack {
                    Text("Password")
                    Spacer()
                    SecureField("", text: $qbitPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            } header: {
                Text("Downloads")
            } footer: {
                Text("qBittorrent's Web UI address. The password is moved into the Keychain on the next refresh and this field is blanked, so it never settles in a preferences file. Leave the username empty if the Web UI is set to skip authentication on the local subnet.")
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Notch tabs")
    }
}
