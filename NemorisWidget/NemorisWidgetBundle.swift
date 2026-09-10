//
//  NemorisWidgetBundle.swift
//  NemorisWidget
//
//  Created by Edwin Helet on 20/05/2026.
//

import WidgetKit
import SwiftUI

@main
struct NemorisWidgetBundle: WidgetBundle {
    var body: some Widget {
        NemorisWidget()
        BudgetWidget()
        BudgetLockWidget()
        InvestmentsWidget()
        InvestmentsLockWidget()
        PatrimoineWidget()
        PatrimoineLockWidget()
        TricountWidget()
        TricountLockWidget()
    }
}
