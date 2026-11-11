//
//  ReportScaleView.swift
//  LibreBase
//
//  Created by Michel Storms on 03/06/2026.
//

import MessageUI
import SwiftUI
import UIKit

/// Guided "Report your scale" flow. LibreBase is verified only with the original
/// QardioBase; this lets an owner of another Base model record how their scale
/// talks over Bluetooth (Recon capture) and email it to us so we can try to add
/// support. Everything is disclosed and user-initiated — there is no hidden mode.
struct ReportScaleView: View {
    @EnvironmentObject var scale: ScaleClient
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var showMail = false
    @State private var mailUnavailable = false
    @State private var model: ScaleModelAnswer?
    @State private var connected: YesNo?
    @State private var showedWeight: YesNo?
    /// The scale gets a few seconds to wake before "not found" is shown.
    @State private var scanGracePassed = false

    private var summary: CaptureSummary { CaptureSummary(log: scale.reconLog) }
    /// The form must be complete: blank answers made reports unusable (#56, #62).
    private var canSend: Bool {
        !scale.reconLog.isEmpty && model != nil && connected != nil && showedWeight != nil
    }

    private var capturedLines: Int { scale.reconLog.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if started {
                        captureCard
                        questionsCard
                        sendCard
                    } else {
                        startCard
                    }
                    disclosure
                }
                .padding(20)
            }
            .navigationTitle("Report your scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Stop capturing on every dismissal path (Done *or* swipe-down) so
            // recon mode never leaks past this screen, as the disclosure promises.
            .onDisappear { scale.reconMode = false }
            .sheet(isPresented: $showMail) {
                MailView(
                    recipients: [Constants.supportEmail],
                    subject: "LibreBase — scale report",
                    body: reportBody,
                    attachment: reportAttachment
                ) { _ in showMail = false }
            }
            .alert("Mail isn't set up", isPresented: $mailUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Set up Mail, or email \(Constants.supportEmail) directly — the diagnostic log has been copied to your clipboard so you can paste it in.")
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(Brand.teal)
            Text("Help us support your scale")
                .font(.title2.bold())
            Text("LibreBase is tested with the original QardioBase. If you have a different Qardio Base model, you can record how it talks to LibreBase over Bluetooth and send it to us — it's the fastest way for us to add support.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start the capture, then step on your scale.")
                .font(.headline)
            Button {
                scale.reconMode = true
                scale.startConnect()
                withAnimation { started = true }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    withAnimation { scanGracePassed = true }
                }
            } label: {
                Label("Start diagnostic capture", systemImage: "record.circle")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Step on your scale now", systemImage: "figure.stand")
                .font(.headline)
            Text("Stand still until your weight settles, then step off. LibreBase is recording how your scale communicates — \(capturedLines) line\(capturedLines == 1 ? "" : "s") captured so far.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if scanGracePassed, !summary.qardioFound {
                // Two blank reports had nothing but a scan list (#62).
                Label("No Qardio scale found yet. Step on the scale to wake it, and close the Qardio app on every phone — the scale talks to one app at a time.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !scale.reconLog.isEmpty {
                ScrollView {
                    Text(scale.reconLog.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private var questionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About your scale")
                .font(.headline)
            Picker("Scale model", selection: $model) {
                Text("Choose…").tag(ScaleModelAnswer?.none)
                ForEach(ScaleModelAnswer.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            .tint(Brand.teal)
            answerRow("Did LibreBase connect to the scale?", $connected)
            answerRow("Did LibreBase show a weight?", $showedWeight)
        }
    }

    private func answerRow(_ question: String, _ answer: Binding<YesNo?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question)
                .font(.subheadline)
            Picker(question, selection: answer) {
                ForEach(YesNo.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var sendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Then send it over")
                .font(.headline)
            Button {
                sendReport()
            } label: {
                Label("Send report", systemImage: "paperplane.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        canSend ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
            .disabled(!canSend)
            if !canSend {
                Text(scale.reconLog.isEmpty ? "Step on the scale first, then answer the questions above."
                                            : "Answer the questions above to send.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var disclosure: some View {
        Text("This records only your scale's Bluetooth data plus your device and app version — nothing else, and only while this screen is capturing. We use it solely to add support for your scale.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Report

    private func sendReport() {
        let full = reportBody + "\n\n— Bluetooth capture —\n" + scale.reconLog.joined(separator: "\n")
        UIPasteboard.general.string = full
        if MFMailComposeViewController.canSendMail() {
            showMail = true
        } else {
            mailUnavailable = true
        }
    }

    private var reportBody: String {
        """
        I'd like to help add support for my Qardio scale.

        My scale model: \(model?.label ?? "—")
        Did LibreBase connect?: \(connected?.rawValue ?? "—")
        Did LibreBase show a weight?: \(showedWeight?.rawValue ?? "—")
        Detected in capture: \(summary.description)

        — Diagnostic info —
        \(Constants.versionLabel)
        iOS \(UIDevice.current.systemVersion) · \(deviceModelIdentifier)
        """
    }

    private var reportAttachment: MailView.Attachment? {
        let text = scale.reconLog.joined(separator: "\n")
        guard let data = text.data(using: .utf8), !text.isEmpty else { return nil }
        return .init(data: data, mimeType: "text/plain", fileName: "librebase-capture.txt")
    }

    /// Hardware identifier (for example "iPhone16,2") — more useful than the generic
    /// `UIDevice.model` when diagnosing a Bluetooth stack difference.
    private var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}

/// The scale models a report can name.
enum ScaleModelAnswer: CaseIterable {
    case original, base2, baseX, notSure

    var label: String {
        switch self {
        case .original: "QardioBase (original)"
        case .base2: "QardioBase 2"
        case .baseX: "QardioBase X"
        case .notSure: "Not sure"
        }
    }
}

enum YesNo: String, CaseIterable { case yes = "Yes", no = "No" }

/// What a Recon capture shows on its own, so a report says it even when the
/// sender's answers don't (#56, #62).
struct CaptureSummary: Equatable {
    var qardioFound = false
    /// Model Number String, decoded from its hex bytes ("B100", "B200", "BX00").
    var modelNumber: String?
    var gotMeasurement = false

    init(log: [String]) {
        for line in log {
            if line.hasPrefix("found peripheral:"), line.localizedCaseInsensitiveContains("qardio") { qardioFound = true }
            if line.hasPrefix("<- Model Number String: ") {
                let bytes = line.dropFirst("<- Model Number String: ".count).split(separator: " ").compactMap { UInt8($0, radix: 16) }
                let decoded = String(bytes: bytes.filter { $0 != 0 }, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespaces)
                modelNumber = decoded?.isEmpty == false ? decoded : nil
                qardioFound = true
            }
            if line.hasPrefix("<- 2A9D:") || line.hasPrefix("qardio measurement JSON decoded") { gotMeasurement = true }
        }
    }

    var description: String {
        guard qardioFound else { return "no Qardio scale found" }
        return "model \(modelNumber ?? "unknown"), \(gotMeasurement ? "measurement received" : "no measurement")"
    }
}

/// Thin wrapper around `MFMailComposeViewController` so SwiftUI can present a
/// prefilled mail draft (with the capture log attached) for the user to send.
struct MailView: UIViewControllerRepresentable {
    struct Attachment {
        let data: Data
        let mimeType: String
        let fileName: String
    }

    let recipients: [String]
    let subject: String
    let body: String
    let attachment: Attachment?
    let onFinish: (Result<MFMailComposeResult, Error>) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(recipients)
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        if let attachment {
            controller.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (Result<MFMailComposeResult, Error>) -> Void
        init(onFinish: @escaping (Result<MFMailComposeResult, Error>) -> Void) {
            self.onFinish = onFinish
        }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            if let error { onFinish(.failure(error)) } else { onFinish(.success(result)) }
        }
    }
}
