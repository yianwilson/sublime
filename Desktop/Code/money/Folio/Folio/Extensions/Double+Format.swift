import Foundation

extension Double {

    /// Currency string. Auto-scales decimal places based on magnitude.
    func asCurrency(code: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle   = .currency
        formatter.currencyCode  = code
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: self)) ?? "$\(self)"
    }

    /// Currency with explicit +/- sign.
    func asChange(code: String = "USD") -> String {
        let sign = self >= 0 ? "+" : ""
        return sign + asCurrency(code: code)
    }

    /// Percentage with sign, e.g. "+3.42%".
    func asPercent(digits: Int = 2) -> String {
        let sign = self >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.\(digits)f", self))%"
    }

    /// Quantity: whole number if integer, otherwise 4 decimal places.
    func asQuantity() -> String {
        self == Double(Int(self)) ? String(format: "%.0f", self) : String(format: "%.4f", self)
    }
}
