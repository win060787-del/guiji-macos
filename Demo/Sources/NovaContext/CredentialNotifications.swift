import ContextCore
import Foundation
import UserNotifications

struct ReminderDeliveryState {
  let key: String
  let pending: Int
  let deferred: Int
}
actor CredentialNotifications {
  func reconcile(_ records: [CredentialRecord], requestPermission: Bool) async
    -> ReminderDeliveryState
  {
    guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
      return ReminderDeliveryState(key: "需从应用启动通知服务", pending: 0, deferred: 0)
    }
    let center = UNUserNotificationCenter.current()
    var settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined && requestPermission {
      do { _ = try await center.requestAuthorization(options: [.alert, .sound]) } catch {
        return ReminderDeliveryState(key: "通知授权失败", pending: 0, deferred: 0)
      }
      settings = await center.notificationSettings()
    }
    let pending = await center.pendingNotificationRequests()
    center.removePendingNotificationRequests(
      withIdentifiers: pending.map(\.identifier).filter {
        $0.hasPrefix(CredentialReminderPlan.prefix)
      })
    let delivered = await center.deliveredNotifications()
    center.removeDeliveredNotifications(
      withIdentifiers: delivered.map { $0.request.identifier }.filter {
        $0.hasPrefix(CredentialReminderPlan.prefix)
      })
    guard
      settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    else {
      return ReminderDeliveryState(
        key: settings.authorizationStatus == .denied ? "通知未授权" : "提醒未开启", pending: 0, deferred: 0)
    }
    let plan = CredentialReminderPlan.make(records)
    var count = 0
    do {
      for item in plan.prefix(48) {
        let content = UNMutableNotificationContent()
        content.title = item.kind == "到期" ? L("凭证到期提醒") : L("凭证轮换提醒")
        content.body = item.name + (item.projectNames.isEmpty ? "" : " · " + item.projectNames)
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(
          dateMatching: Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: item.date), repeats: false)
        try await center.add(
          UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
        count += 1
      }
      return ReminderDeliveryState(
        key: "本机提醒已开启", pending: count, deferred: max(0, plan.count - 48))
    } catch {
      return ReminderDeliveryState(
        key: "部分提醒未排入，重新同步可重试", pending: count, deferred: max(0, plan.count - count))
    }
  }
}
