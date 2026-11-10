import Foundation

public enum CredentialLifecycle: String, Sendable {
  case normal = "正常"
  case soon = "临近到期"
  case expired = "已到期"
  case rotationDue = "待轮换"
}
extension CredentialRecord {
  public func lifecycle(at now: Date = Date()) -> CredentialLifecycle {
    if let expiresAt, expiresAt <= now { return .expired }
    if let rotateAt, rotateAt <= now { return .rotationDue }
    if let next = [expiresAt, rotateAt].compactMap({ $0 }).min(),
      next.timeIntervalSince(now) <= 7 * 86400
    {
      return .soon
    }
    return .normal
  }
}
public struct CredentialReminder: Equatable, Sendable {
  public let id: String
  public let date: Date
  public let name: String
  public let kind: String
  public let projectNames: String
}
public enum CredentialReminderPlan {
  public static let prefix = "nova.credential."
  /// A bounded scheduling window; overdue items remain visible in the vault.
  public static func make(
    _ records: [CredentialRecord], now: Date = Date(), calendar: Calendar = .current
  ) -> [CredentialReminder] {
    var result: [CredentialReminder] = []
    for record in records where record.remindersEnabled == true {
      for (kind, date) in [("到期", record.expiresAt), ("轮换", record.rotateAt)] {
        guard let date else { continue }
        for days in Set(record.reminderDays ?? [7, 1, 0]).filter({ (0...30).contains($0) }) {
          guard let target = calendar.date(byAdding: .day, value: -days, to: date), target > now
          else { continue }
          result.append(
            CredentialReminder(
              id: prefix + record.id.uuidString + "." + kind + ".\(days)", date: target,
              name: record.name, kind: kind,
              projectNames: record.projects.map(\.name).joined(separator: "、")))
        }
      }
    }
    return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
  }
}
