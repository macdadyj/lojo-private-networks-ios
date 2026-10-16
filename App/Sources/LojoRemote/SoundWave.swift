import Foundation

/// Short looping sound-machine clips. Generated in memory so the repo stays free of binary blobs.
public enum SoundWave {
    public static func wav(for sound: BundledSound, sampleRate: Int = 22_050, seconds: Double = 1) -> Data {
        let count = max(1, Int((Double(sampleRate) * seconds).rounded()))
        var rng = SplitMix64(state: seed(for: sound))
        var samples = [Int16](repeating: 0, count: count)
        var brown = 0.0
        for index in 0..<count {
            let t = Double(index) / Double(sampleRate)
            let noise = rng.bipolar()
            let shaped: Double
            switch sound {
            case .whiteNoise:
                shaped = noise * 0.35
            case .pinkNoise:
                shaped = rng.pink() * 0.45
            case .brownNoise:
                brown = max(-1, min(1, brown + noise * 0.04))
                shaped = brown * 0.55
            case .rain:
                let drip = 0.25 + 0.75 * abs(sin(t * 7.2))
                shaped = noise * 0.32 * drip
            case .fan:
                shaped = sin(2 * Double.pi * 90 * t) * 0.22 + noise * 0.06
            }
            samples[index] = Int16(max(-1, min(1, shaped)) * Double(Int16.max))
        }
        return encode(samples: samples, sampleRate: sampleRate)
    }

    public static func encode(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        data.append(uint32: UInt32(36 + dataSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20]) // fmt
        data.append(uint32: 16)
        data.append(uint16: 1)
        data.append(uint16: 1)
        data.append(uint32: UInt32(sampleRate))
        data.append(uint32: UInt32(sampleRate * 2))
        data.append(uint16: 2)
        data.append(uint16: 16)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        data.append(uint32: UInt32(dataSize))
        for sample in samples {
            data.append(uint16: UInt16(bitPattern: sample))
        }
        return data
    }

    private static func seed(for sound: BundledSound) -> UInt64 {
        switch sound {
        case .whiteNoise: return 0xA11CE
        case .pinkNoise: return 0xB107
        case .brownNoise: return 0xC0FFEE
        case .rain: return 0xD1A1
        case .fan: return 0xF00
        }
    }
}

struct SplitMix64 {
    var state: UInt64
    private var pinkRows: [Double]
    private var pinkKey = 0

    init(state: UInt64) {
        self.state = state
        pinkRows = [Double](repeating: 0, count: 5)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func bipolar() -> Double {
        unit() * 2 - 1
    }

    /// Paul Kellet-style rows, enough to sound softer than white noise on a loop.
    mutating func pink() -> Double {
        pinkKey = (pinkKey + 1) & 31
        if pinkKey & 1 != 0 { pinkRows[0] = bipolar() }
        if pinkKey & 2 != 0 { pinkRows[1] = bipolar() }
        if pinkKey & 4 != 0 { pinkRows[2] = bipolar() }
        if pinkKey & 8 != 0 { pinkRows[3] = bipolar() }
        pinkRows[4] = bipolar()
        return max(-1, min(1, pinkRows.reduce(0, +) / 5))
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
