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

/// Models a user can choose, with an estimated price per minute of audio.
struct TranscriptionModelCatalog: Codable, Equatable {
    let defaultModel: String
    let defaultModelName: String
    let models: [TranscriptionModelOption]
    /// Live transcription models. Absent from older servers, which only
    /// accept uploads.
    var realtime: RealtimeTranscriptionCatalog? = nil

    enum CodingKeys: String, CodingKey {
        case defaultModel = "default_model"
        case defaultModelName = "default_model_name"
        case models, realtime
    }
}

/// Models that transcribe audio while it is spoken, over a WebSocket.
struct RealtimeTranscriptionCatalog: Codable, Equatable {
    /// False when the owner turned live transcription off; the app uploads.
    let available: Bool
    let defaultModel: String
    let models: [RealtimeTranscriptionModel]

    enum CodingKeys: String, CodingKey {
        case available
        case defaultModel = "default_model"
        case models
    }
}

struct RealtimeTranscriptionModel: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let recommended: Bool
    /// True for models that cannot transcribe an uploaded recording.
    let liveOnly: Bool
    /// "while_speaking" or "after_pauses".
    let textTiming: String
    let retiresOn: String?
    let pricingBasis: String
    let creditUnitsPerMinute: Int
    let formattedPerMinute: String

    enum CodingKeys: String, CodingKey {
        case id, name, recommended
        case liveOnly = "live_only"
        case textTiming = "text_timing"
        case retiresOn = "retires_on"
        case pricingBasis = "pricing_basis"
        case creditUnitsPerMinute = "credit_units_per_minute"
        case formattedPerMinute = "formatted_per_minute"
    }
}

struct TranscriptionModelOption: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let recommended: Bool
    let streaming: Bool
    let retiresOn: String?
    let pricingBasis: String
    let creditUnitsPerMinute: Int
    let formattedPerMinute: String

    enum CodingKeys: String, CodingKey {
        case id, name, recommended, streaming
        case retiresOn = "retires_on"
        case pricingBasis = "pricing_basis"
        case creditUnitsPerMinute = "credit_units_per_minute"
        case formattedPerMinute = "formatted_per_minute"
    }
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
