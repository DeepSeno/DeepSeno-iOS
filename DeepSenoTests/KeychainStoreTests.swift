import XCTest
@testable import DeepSeno

final class KeychainStoreTests: XCTestCase {
    let account = "deepseno_test_token"

    override func tearDown() {
        KeychainStore.deleteToken(account: account)
        UserDefaults.standard.removeObject(forKey: "deepseno_test_migrate_token")
        UserDefaults.standard.removeObject(forKey: "deepseno_test_migrate_token2")
        super.tearDown()
    }

    func test_setAndGet_roundTrip() {
        KeychainStore.setToken("abc123", account: account)
        XCTAssertEqual(KeychainStore.token(account: account), "abc123")
    }

    func test_overwrite_updatesValue() {
        KeychainStore.setToken("first", account: account)
        KeychainStore.setToken("second", account: account)
        XCTAssertEqual(KeychainStore.token(account: account), "second")
    }

    func test_delete_removesValue() {
        KeychainStore.setToken("abc123", account: account)
        KeychainStore.deleteToken(account: account)
        XCTAssertNil(KeychainStore.token(account: account))
    }

    func test_missing_returnsNil() {
        XCTAssertNil(KeychainStore.token(account: "never_written_xyz"))
    }

    func test_migrateFromUserDefaults_movesAndClears() {
        let udKey = "deepseno_test_migrate_token"
        let defaults = UserDefaults.standard
        defaults.set("legacy-token", forKey: udKey)
        KeychainStore.deleteToken(account: account)

        KeychainStore.migrateTokenIfNeeded(userDefaultsKey: udKey, account: account)

        XCTAssertEqual(KeychainStore.token(account: account), "legacy-token")
        XCTAssertNil(defaults.string(forKey: udKey), "明文 token 应被清除")
    }

    func test_migrate_noopWhenKeychainAlreadyHasToken() {
        let udKey = "deepseno_test_migrate_token2"
        UserDefaults.standard.set("legacy", forKey: udKey)
        KeychainStore.setToken("existing", account: account)

        KeychainStore.migrateTokenIfNeeded(userDefaultsKey: udKey, account: account)

        XCTAssertEqual(KeychainStore.token(account: account), "existing", "已有则不覆盖")
        XCTAssertNil(UserDefaults.standard.string(forKey: udKey))
    }
}
