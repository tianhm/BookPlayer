//
//  AccountService.swift
//  BookPlayer
//
//  Created by gianni.carlo on 10/4/22.
//  Copyright © 2022 Tortuga Power. All rights reserved.
//

import CoreData
import Foundation
import RevenueCat

public enum AccountError: Error {
  /// RevenueCat can't find the products
  case emptyProducts
  /// RevenueCat didn't find an active subscription
  case inactiveSubscription
  /// iOS apps running on MacOS can't show subscription management
  case managementUnavailable
  /// Sign in with Apple didn't return identityToken
  case missingToken
}

extension AccountError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .emptyProducts:
      return "Empty products!"
    case .managementUnavailable:
      return "Subscription Management is not available for iOS apps running on Macs, please go to the App Store app to manage your existing subscriptions."
    case .missingToken:
      return "Identity token not available. Please sign in again."
    case .inactiveSubscription:
      return "We couldn't find an active subscription for your account. If you believe this is an error, please contact us at support@bookplayer.app"
    }
  }
}

public protocol AccountServiceProtocol {
  func getAccountId() -> String?
  func getAccount() -> Account?
  func hasAccount() -> Bool

  func createAccount(donationMade: Bool)

  func setDelegate(_ delegate: PurchasesDelegate)

  func updateAccount(from customerInfo: CustomerInfo)

  func updateAccount(
    id: String?,
    email: String?,
    donationMade: Bool?,
    hasSubscription: Bool?
  )

  func subscribe() async throws -> Bool
  func restorePurchases() async throws -> CustomerInfo

  func loginIfUserExists()
  func login(
    with token: String,
    userId: String
  ) async throws -> Account?

  func logout() throws
  func deleteAccount() async throws -> String
}

public final class AccountService: AccountServiceProtocol {
  let subscriptionId = "com.tortugapower.audiobookplayer.subscription.pro"
  let apiURL = "https://api.tortugapower.com"
  let dataManager: DataManager
  let client: NetworkClientProtocol
  let keychain: KeychainServiceProtocol
  private let provider: NetworkProvider<AccountAPI>

  public init(
    dataManager: DataManager,
    client: NetworkClientProtocol = NetworkClient(),
    keychain: KeychainServiceProtocol = KeychainService()
  ) {
    self.dataManager = dataManager
    self.client = client
    self.keychain = keychain
    self.provider = NetworkProvider(client: client)
  }

  public func setDelegate(_ delegate: PurchasesDelegate) {
    Purchases.shared.delegate = delegate
  }

  public func getAccountId() -> String? {
    if let account = self.getAccount(),
       !account.id.isEmpty {
      return account.id
    } else {
      return nil
    }
  }

  public func getAccount() -> Account? {
    let context = self.dataManager.getContext()
    let fetch: NSFetchRequest<Account> = Account.fetchRequest()
    fetch.returnsObjectsAsFaults = false

    return (try? context.fetch(fetch).first)
  }

  public func hasAccount() -> Bool {
    let context = self.dataManager.getContext()

    if let count = try? context.count(for: Account.fetchRequest()),
        count > 0 {
      return true
    }

    return false
  }

  public func createAccount(donationMade: Bool) {
    let context = self.dataManager.getContext()
    let account = Account.create(in: context)
    account.id = ""
    account.email = ""
    account.hasSubscription = false
    account.donationMade = donationMade
    self.dataManager.saveContext()
  }

  public func updateAccount(from customerInfo: CustomerInfo) {
    self.updateAccount(
      hasSubscription: !customerInfo.activeSubscriptions.isEmpty
    )
  }

  public func updateAccount(
    id: String? = nil,
    email: String? = nil,
    donationMade: Bool? = nil,
    hasSubscription: Bool? = nil
  ) {
    guard let account = self.getAccount() else { return }

    if let id = id {
      account.id = id
    }

    if let email = email {
      account.email = email
    }

    if let donationMade = donationMade {
      account.donationMade = donationMade
    }

    if let hasSubscription = hasSubscription {
      account.hasSubscription = hasSubscription
    }

    self.dataManager.saveContext()

    NotificationCenter.default.post(name: .accountUpdate, object: self)
  }

  public func subscribe() async throws -> Bool {
    let products = await Purchases.shared.products([self.subscriptionId])

    guard let product = products.first else {
      throw AccountError.emptyProducts
    }

    let result = try await Purchases.shared.purchase(product: product)

    if !result.userCancelled {
      self.updateAccount(donationMade: true, hasSubscription: true)
    }

    return result.userCancelled
  }

  public func restorePurchases() async throws -> CustomerInfo {
    return try await Purchases.shared.restorePurchases()
  }

  public func login(
    with token: String,
    userId: String
  ) async throws -> Account? {
    let response: LoginResponse = try await provider.request(.login(token: token))

    try self.keychain.setAccessToken(response.token)

    let (customerInfo, _) = try await Purchases.shared.logIn(userId)

    if let existingAccount = self.getAccount() {
      // Preserve donation made flag from stored account
      let donationMade = existingAccount.donationMade || !customerInfo.nonSubscriptions.isEmpty

      self.updateAccount(
        id: userId,
        email: response.email,
        donationMade: donationMade,
        hasSubscription: !customerInfo.activeSubscriptions.isEmpty
      )
    }

    NotificationCenter.default.post(name: .login, object: self)

    return self.getAccount()
  }

  public func loginIfUserExists() {
    guard let account = self.getAccount(), !account.id.isEmpty else { return }

    Purchases.shared.logIn(account.id) { [weak self] customerInfo, _, _ in
      guard let customerInfo = customerInfo else { return }

      self?.updateAccount(from: customerInfo)
    }
  }

  public func logout() throws {
    try self.keychain.removeAccessToken()

    self.updateAccount(
      id: "",
      email: "",
      hasSubscription: false
    )

    Purchases.shared.logOut { _, _ in }
  }

  public func deleteAccount() async throws -> String {
    let response: DeleteResponse = try await provider.request(.delete)

    try logout()

    return response.message
  }
}
