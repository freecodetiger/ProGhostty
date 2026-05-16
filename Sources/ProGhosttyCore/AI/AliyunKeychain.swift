import Foundation

#if canImport(Security)
import Security
#endif

public enum AliyunKeychain {
  private static let service = "ProGhostty.AliyunASR"
  private static let account = "DASHSCOPE_API_KEY"

  public static func readAPIKey() -> String? {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
    #else
    return nil
    #endif
  }

  public static func saveAPIKey(_ apiKey: String) throws {
    #if canImport(Security)
    let data = Data(apiKey.utf8)
    let baseQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    var addQuery = baseQuery
    addQuery[kSecValueData as String] = data
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw AliyunKeychainError.operationFailed(addStatus)
    }
    #endif
  }

  public static func deleteAPIKey() throws {
    #if canImport(Security)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AliyunKeychainError.operationFailed(status)
    }
    #endif
  }
}

public enum AliyunKeychainError: Error, Equatable {
  case operationFailed(OSStatus)
}
