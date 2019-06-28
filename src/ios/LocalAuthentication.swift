//
//  LocalAuthentication.swift
//  AGUtilities
//
//  Created by Mike Godenzi on 25.06.19.
//  Copyright © 2019 Mike Godenzi. All rights reserved.
//

import Foundation
import LocalAuthentication

public class LocalAuthentication {

	public static let shared = LocalAuthentication()
	private static var automaticKey = "local_auth_automatic"
	private static var authenticationReasonKey = "local_auth_reason"
	private static var defaultAuthenticationReason = "Please authenticate to continue to use the app."

	private lazy var context: LAContext = {
		let result = LAContext()
		result.localizedReason = self.localizedAuthenticationReason
		return result
	}()
	private var queue: OperationQueue = {
		let result = OperationQueue()
		result.maxConcurrentOperationCount = 1
		result.name = "ch.papers.security-utils.LocalAuthentication"
		return result
	}()
	private var lastAuthentication: Date = .distantFuture
	private var lastBackground: Date?
	public var invalidateAfter: TimeInterval = 10

	private var defaults: UserDefaults {
		return UserDefaults.standard
	}
	public var automatic: Bool {
		get {
			return defaults.bool(forKey: LocalAuthentication.automaticKey)
		}
		set {
			let current = self.automatic
			guard current != newValue else {
				return
			}
			defaults.set(newValue, forKey: LocalAuthentication.automaticKey)
			updateAutomaticAuthenticationIfNeeded()
		}
	}
	public var localizedAuthenticationReason: String {
		get {
			return defaults.string(forKey: LocalAuthentication.authenticationReasonKey) ?? LocalAuthentication.defaultAuthenticationReason
		}
		set {
			defaults.set(newValue, forKey: LocalAuthentication.authenticationReasonKey)
			context.localizedReason = newValue
		}
	}
	private var didBecomeActiveObserver: Observer?
	private var didEnterBackgroundObserver: Observer?

	private var needsAccessInvalidation: Bool {
		let now = Date()
		return now > lastAuthentication.addingTimeInterval(invalidateAfter)
	}
	private var needsAuthenticationInvalidation: Bool {
		guard let lastBackground = self.lastBackground else {
			return false
		}
		let now = Date()
		return now > lastBackground.addingTimeInterval(invalidateAfter)
	}

	public func authenticateAccess(for accessOperation: LAAccessControlOperation, localizedReason reason: String? = nil, handler: @escaping (Result<(Bool, LAContext), Error>) -> ()) {
		let operation = AuthenticateAccessOperation(localAuth: self)
		operation.localizedReason = reason ?? context.localizedReason
		operation.accessOperation = accessOperation
		if needsAccessInvalidation {
			print("ACCESS INVALIDATING")
			operation.addDependency(createInvalidateOperation())
		}
		operation.completionBlock = { [unowned operation] in
			guard let error = operation.error else {
				self.lastAuthentication = Date()
				handler(.success((operation.result, self.context)))
				return
			}
			handler(.failure(Error(error)))
		}
		enqueue(operation)
	}

	public func authenticate(localizedReason reason: String? = nil, handler: @escaping (Result<Bool, Error>) -> ()) {
		let operation = AuthenticationOperation(localAuth: self)
		operation.localizedReason = reason ?? context.localizedReason
		if needsAuthenticationInvalidation {
			print("AUTH INVALIDATING")
			operation.addDependency(createInvalidateOperation())
		}
		lastBackground = nil
		operation.completionBlock = { [unowned operation] in
			guard let error = operation.error else {
				self.lastAuthentication = Date()
				handler(.success(operation.result))
				return
			}
			handler(.failure(Error(error)))
		}
		enqueue(operation)
	}

	public func invalidate(completion: @escaping () -> ()) {
		let operation = createInvalidateOperation()
		operation.completionBlock = completion
		queue.addOperation(operation)
	}

	public func setInvalidationTimeout(_ timeout: TimeInterval) {
		queue.addOperation {
			self.invalidateAfter = timeout
		}
	}

	public func updateAutomaticAuthenticationIfNeeded() {
		if automatic && didBecomeActiveObserver == nil {
			didBecomeActiveObserver = Observer(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared) { [unowned self] _ in
				self.authenticate() { result in
					if case let .failure(error) = result {
						print(error)
					}
				}
			}
			didEnterBackgroundObserver = Observer(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared) { [unowned self] _ in
				print("SETTING BACKGROUND DATE")
				self.lastBackground = Date()
			}
		} else if !automatic && didBecomeActiveObserver != nil {
			didBecomeActiveObserver = nil
			didEnterBackgroundObserver = nil
		}
	}

	private func createInvalidateOperation() -> Operation {
		return BlockOperation {
			let context = LAContext()
			context.localizedReason = self.localizedAuthenticationReason
			self.context.invalidate()
			self.context = context
		}
	}

	private func enqueue(_ operation: Operation) {
		for dependent in operation.dependencies where !dependent.isFinished && !dependent.isExecuting {
			queue.addOperation(dependent)
		}
		queue.addOperation(operation)
	}

	public enum Error: Swift.Error {
		case unknown
		case `internal`(Swift.Error)
		case cancelled

		init(_ error: Swift.Error?) {
			if let error = error {
				self = .internal(error)
			} else {
				self = .unknown
			}
		}
	}

	class AsyncOperation: Operation {

		override open var isAsynchronous: Bool {
			return true
		}

		private var _isExecuring: Bool = false
		private static let isExecutingKey = "isExecuting"
		override open var isExecuting: Bool {
			get {
				return _isExecuring
			}
			set {
				willChangeValue(forKey: AsyncOperation.isExecutingKey)
				_isExecuring = newValue
				didChangeValue(forKey: AsyncOperation.isExecutingKey)
			}
		}

		private var _isFinished: Bool = false
		private static let isFinishedKey = "isFinished"
		override open var isFinished: Bool {
			get {
				return _isFinished
			}
			set {
				willChangeValue(forKey: AsyncOperation.isFinishedKey)
				_isFinished = newValue
				didChangeValue(forKey: AsyncOperation.isFinishedKey)
			}
		}

		var error: Error?

		override func start() {
			guard !isCancelled else {
				return
			}

			isExecuting = true

			perform {
				self.stop()
			}
		}

		func perform(completion: @escaping () -> ()) {
			completion()
		}

		override open func cancel() {
			isFinished = true
			isExecuting = false
			if error == nil {
				error = .cancelled
			}
			super.cancel()
		}

		func cancel(with error: Error) {
			self.error = error
			self.cancel()
		}

		func stop() {
			isFinished = true
			isExecuting = false
		}
	}

	class AuthenticationOperation: AsyncOperation {

		unowned let localAuth: LocalAuthentication
		var context: LAContext {
			return localAuth.context
		}
		var policy: LAPolicy = .deviceOwnerAuthentication
		var localizedReason: String = "Please authenticate"
		private(set) var result: Bool = false

		init(localAuth: LocalAuthentication) {
			self.localAuth = localAuth
		}

		override func perform(completion: @escaping () -> ()) {
			context.evaluatePolicy(policy, localizedReason: localizedReason) { (result, error) in
				self.result = result
				self.error = (error != nil) ? Error(error) : nil
				completion()
			}
		}
	}

	class AuthenticateAccessOperation: AsyncOperation {

		unowned let localAuth: LocalAuthentication
		var context: LAContext {
			return localAuth.context
		}
		var accessOperation: LAAccessControlOperation = .useItem
		var localizedReason: String = "Please authenticate"
		private(set) var result: Bool = false

		init(localAuth: LocalAuthentication) {
			self.localAuth = localAuth
		}

		override func perform(completion: @escaping () -> ()) {
			var error: Unmanaged<CFError>? = nil
			guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.userPresence], &error) else {
				self.error = Error(error?.autorelease().takeUnretainedValue())
				completion()
				return
			}
			context.evaluateAccessControl(access, operation: accessOperation, localizedReason: localizedReason) { (result, error) in
				defer { completion() }
				guard let error = error else {
					self.result = result
					return
				}
				self.error = Error(error)
			}
		}
	}
}