import Foundation
import LedgerCore

/// An explicitly synthetic 1:1 reference keeps existing accounting examples
/// independent of networking. Production records never assume this rate.
func syntheticEntry(id: UUID = UUID(), date: Date = Date(), sequence: Int64 = 0,
                    kind: EntryKind, fromAccountID: UUID? = nil, toAccountID: UUID? = nil,
                    amountSats: Int64 = 0, receivedSats: Int64 = 0,
                    amountCNY: Decimal = 0, conversion: PurchaseConversion? = nil,
                    note: String = "") -> LedgerEntry {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let rate = USDExchangeRate(date: calendar.startOfDay(for: date).addingTimeInterval(-86_400),
                              cnyPerUSD: 1, source: "合成测试汇率")
    let synthetic = kind == .buy ? try? PurchaseConversion.make(amountCNY: amountCNY, rate: rate) : nil
    return LedgerEntry(id: id, date: date, sequence: sequence, kind: kind,
        fromAccountID: fromAccountID, toAccountID: toAccountID, amountSats: amountSats,
        receivedSats: receivedSats, amountCNY: amountCNY, conversion: conversion ?? synthetic, note: note)
}
