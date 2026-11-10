import Foundation

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case language, project, appearance, access
    public var title: String {
        switch self { case .language: return L("选择语言"); case .project: return L("选择项目"); case .appearance: return L("选择外观"); case .access: return L("准备就绪") }
    }
}
public struct OnboardingFlow: Sendable {
    public private(set) var step: OnboardingStep = .language
    public private(set) var completed = false
    public init() {}
    @discardableResult public mutating func next(hasProject: Bool) -> Bool {
        guard !completed else { return false }
        if step == .project && !hasProject { return false }
        if step == .access { completed = true } else { step = OnboardingStep(rawValue: step.rawValue + 1)! }
        return true
    }
    public mutating func back() {
        guard !completed, step.rawValue > 0 else { return }
        step = OnboardingStep(rawValue: step.rawValue - 1)!
    }
    public mutating func skip() { completed = true }
}
