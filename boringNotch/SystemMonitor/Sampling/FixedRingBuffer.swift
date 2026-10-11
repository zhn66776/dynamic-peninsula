import Foundation

struct FixedRingBuffer<Element>: Sendable where Element: Sendable {
    let capacity: Int

    private var storage: [Element?]
    private var startIndex = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0, "Ring buffer capacity must be positive")
        self.capacity = capacity
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        if count < capacity {
            storage[(startIndex + count) % capacity] = element
            count += 1
        } else {
            storage[startIndex] = element
            startIndex = (startIndex + 1) % capacity
        }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        startIndex = 0
        count = 0
    }

    mutating func removeAll(where shouldRemove: (Element) throws -> Bool) rethrows {
        let retained = try elements.filter { try !shouldRemove($0) }
        removeAll()
        for element in retained {
            append(element)
        }
    }

    var elements: [Element] {
        (0..<count).map { offset in
            storage[(startIndex + offset) % capacity]!
        }
    }
}

extension FixedRingBuffer: Equatable where Element: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.capacity == rhs.capacity && lhs.elements == rhs.elements
    }
}
