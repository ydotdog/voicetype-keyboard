import Foundation

struct AuthResponse: Decodable {
    let token: String
    let user: UserProfile
    let balance: BalancePayload
}

struct UserProfile: Codable, Identifiable {
    let id: String
    let email: String?
}

struct BalancePayload: Codable {
    let balanceUSDMicros: Int
    let balanceCreditUnits: Int?
    let formatted: String

    enum CodingKeys: String, CodingKey {
        case balanceUSDMicros = "balance_usd_micros"
        case balanceCreditUnits = "balance_credit_units"
        case formatted
    }
}

struct ProductCatalogResponse: Decodable {
    let products: [CreditProduct]
}

struct CreditProduct: Codable, Identifiable {
    let id: String
    let displayName: String
    let creditUSDMicros: Int
    let creditUnits: Int?
    let subtitle: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case creditUSDMicros = "credit_usd_micros"
        case creditUnits = "credit_units"
        case subtitle
    }
}

struct StoreKitTransactionRequest: Encodable {
    let signedTransaction: String

    enum CodingKeys: String, CodingKey {
        case signedTransaction = "signed_transaction"
    }
}

struct DevCreditRequest: Encodable {
    let amountUSDMicros: Int

    enum CodingKeys: String, CodingKey {
        case amountUSDMicros = "amount_usd_micros"
    }
}

struct PurchaseCreditResponse: Decodable {
    let balance: BalancePayload
    let grantedUSDMicros: Int
    let grantedCreditUnits: Int?
    let alreadyProcessed: Bool

    enum CodingKeys: String, CodingKey {
        case balance
        case grantedUSDMicros = "granted_usd_micros"
        case grantedCreditUnits = "granted_credit_units"
        case alreadyProcessed = "already_processed"
    }
}

struct TranscriptionResponse: Decodable {
    let id: String
    let transcript: String
    let model: String
    let charge: ChargePayload
    let balance: BalancePayload
}

struct ChargePayload: Codable {
    let costUSDMicros: Int
    let costCreditUnits: Int?
    let formatted: String
    let pricingBasis: String

    enum CodingKeys: String, CodingKey {
        case costUSDMicros = "cost_usd_micros"
        case costCreditUnits = "cost_credit_units"
        case formatted
        case pricingBasis = "pricing_basis"
    }
}
