import Foundation

struct CategoryTotal: Hashable {
    let category: ExpenseCategory
    let total: Decimal
    let count: Int
}

enum CategoryTotals {
    /// Totals + counts per category present in `expenses`, sorted by total descending.
    /// Categories with zero expenses are omitted.
    static func totals(for expenses: [Expense]) -> [CategoryTotal] {
        var byCategory: [ExpenseCategory: (total: Decimal, count: Int)] = [:]
        for e in expenses {
            var existing = byCategory[e.category] ?? (total: 0, count: 0)
            existing.total += e.amount
            existing.count += 1
            byCategory[e.category] = existing
        }
        return byCategory
            .map { CategoryTotal(category: $0.key, total: $0.value.total, count: $0.value.count) }
            .sorted { $0.total > $1.total }
    }

    static func counts(for expenses: [Expense]) -> [ExpenseCategory: Int] {
        var out: [ExpenseCategory: Int] = [:]
        for e in expenses {
            out[e.category, default: 0] += 1
        }
        return out
    }
}
