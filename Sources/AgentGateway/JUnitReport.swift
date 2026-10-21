import Foundation
import AgentCore

/// A run report as JUnit XML, the format CI systems (GitHub Actions, Jenkins, GitLab) read for test results.
/// One `testsuite` per run and one `testcase` per step of the case; the run's own steps (actions the runner took) are folded into their step.
enum JUnitReport {
    static func xml(_ runs: [(id: String, report: CaseRunReport)]) -> String {
        var out = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<testsuites>"]
        for run in runs {
            let steps = grouped(run.report)
            let failures = steps.filter { $0.status == .failed }.count
            let skipped = steps.filter { [.skipped, .pending, .unsupported].contains($0.status) }.count
            let seconds = run.report.finishedAt.map { $0.timeIntervalSince(run.report.startedAt) } ?? 0
            out.append("  <testsuite name=\"\(escape(run.report.testKey))\" id=\"\(escape(run.id))\" tests=\"\(steps.count)\" failures=\"\(failures)\" errors=\"0\" skipped=\"\(skipped)\" time=\"\(format(seconds))\" timestamp=\"\(timestamp(run.report.startedAt))\">")
            out.append("    <properties><property name=\"title\" value=\"\(escape(run.report.title))\"/><property name=\"outcome\" value=\"\(escape(run.report.outcome))\"/></properties>")
            for step in steps {
                let name = escape("Step \(step.number): \(step.intent)")
                switch step.status {
                case .failed:
                    out.append("    <testcase classname=\"\(escape(run.report.testKey))\" name=\"\(name)\"><failure message=\"\(escape(String(step.detail.prefix(200))))\">\(escape(step.detail))</failure></testcase>")
                case .skipped, .pending, .unsupported:
                    out.append("    <testcase classname=\"\(escape(run.report.testKey))\" name=\"\(name)\"><skipped message=\"\(escape(step.detail.isEmpty ? step.status.rawValue : String(step.detail.prefix(200))))\"/></testcase>")
                default:
                    out.append("    <testcase classname=\"\(escape(run.report.testKey))\" name=\"\(name)\"/>")
                }
            }
            out.append("  </testsuite>")
        }
        out.append("</testsuites>")
        return out.joined(separator: "\n")
    }

    private struct StepResult { let number: Int; let intent: String; let status: CaseRunReport.Status; let detail: String }

    /// A step fails when any of its actions failed, is skipped when none ran, and otherwise passes. The first failure's detail is kept.
    private static func grouped(_ report: CaseRunReport) -> [StepResult] {
        var order: [Int] = []
        var rows: [Int: [CaseRunReport.Step]] = [:]
        for step in report.steps {
            if rows[step.sourceStepNumber] == nil { order.append(step.sourceStepNumber) }
            rows[step.sourceStepNumber, default: []].append(step)
        }
        return order.sorted().map { number in
            let items = rows[number] ?? []
            let failed = items.first { $0.status == .failed }
            let status: CaseRunReport.Status = failed != nil ? .failed : (items.allSatisfy { [.skipped, .pending, .unsupported].contains($0.status) } ? .skipped : .passed)
            return StepResult(number: number, intent: planned(report, number) ?? items.first?.intent ?? "Step \(number)", status: status, detail: failed?.detail ?? items.first { !$0.detail.isEmpty }?.detail ?? "")
        }
    }

    private static func planned(_ report: CaseRunReport, _ number: Int) -> String? { report.plannedSteps?.first { $0.number == number }?.text }

    private static func format(_ seconds: TimeInterval) -> String { String(format: "%.1f", max(0, seconds)) }

    private static func timestamp(_ date: Date) -> String { date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)) }

    /// XML text with the five reserved characters escaped and the control characters XML 1.0 cannot carry dropped.
    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default: if scalar.value >= 0x20 { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
}
