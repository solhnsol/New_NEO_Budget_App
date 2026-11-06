#if DEBUG
import SwiftUI

/// Launch aid for checking a settings screen against its mockup without tapping: `-more-screen <name>` (names below), `-tab-more` opens the tab.
enum MoreGallery {
    static func screen(_ name: String, model: AppModel) -> AnyView? {
        switch name {
        case "shortcuts": return AnyView(NavigationStack { ShortcutsScreen(model: model) })
        case "inbox": return AnyView(NavigationStack { IntakeInboxView(model: model) })
        case "rules": return AnyView(NavigationStack { RulesScreen() })
        case "rule-edit": return AnyView(NavigationStack { RuleEditScreen(rule: nil, sample: nil) })
        case "settlement": return AnyView(NavigationStack { NotificationKindScreen(model: model, kind: .settlement) })
        case "budget-alert": return AnyView(NavigationStack { NotificationKindScreen(model: model, kind: .budget) })
        case "event-alert": return AnyView(NavigationStack { NotificationKindScreen(model: model, kind: .eventSpending) })
        case "category-alert": return AnyView(NavigationStack { NotificationKindScreen(model: model, kind: .categoryRequest) })
        case "quiet": return AnyView(NavigationStack { QuietHoursScreen() })
        case "data": return AnyView(NavigationStack { DataTransferScreen(model: model) })
        case "settlement-settings": return AnyView(NavigationStack { SettlementSettingsScreen() })
        case "budget": return AnyView(NavigationStack { BudgetScreen() })
        default: return nil
        }
    }
}
#endif
