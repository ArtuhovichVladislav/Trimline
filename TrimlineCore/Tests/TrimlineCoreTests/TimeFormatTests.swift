import Foundation
import Testing

@testable import TrimlineCore

@Suite struct TimeFormatTests {
    private let english = Locale(identifier: "en_US")
    private let russian = Locale(identifier: "ru_RU")

    @Test func formatsMinutesAndSeconds() {
        let format = TimeFormat(fileDuration: 600, locale: english)
        #expect(format.string(from: 0) == "00:00.00")
        #expect(format.string(from: 83.45) == "01:23.45")
        #expect(format.string(from: 3599.99) == "59:59.99")
    }

    @Test func showsHoursForLongFiles() {
        let format = TimeFormat(fileDuration: TimeFormat.hoursThreshold, locale: english)
        #expect(format.string(from: 5) == "0:00:05.00")
        #expect(format.string(from: 3723.5) == "1:02:03.50")
        #expect(format.string(from: 36_000) == "10:00:00.00")
    }

    @Test func minutesExceedSixtyWithoutHours() {
        let format = TimeFormat(fileDuration: 600, locale: english)
        #expect(format.string(from: 3723.5) == "62:03.50")
    }

    @Test func roundsToHundredths() {
        let format = TimeFormat(fileDuration: 600, locale: english)
        #expect(format.string(from: 59.996) == "01:00.00")
        #expect(format.string(from: 1.234) == "00:01.23")
        #expect(format.string(from: 1.237) == "00:01.24")
        #expect(format.string(from: -2) == "00:00.00")
    }

    @Test func russianUsesComma() {
        let format = TimeFormat(fileDuration: 600, locale: russian)
        #expect(format.string(from: 83.45) == "01:23,45")
    }

    @Test func parsesTypedTimes() throws {
        let format = TimeFormat(fileDuration: 600, locale: english)
        #expect(try #require(format.time(from: "83.4")) == 83.4)
        #expect(try #require(format.time(from: "1:02:03.5")) == 3723.5)
        #expect(try #require(format.time(from: " 1:05 ")) == 65)
        #expect(try #require(format.time(from: "0")) == 0)
    }

    @Test func parsesRussianComma() throws {
        let format = TimeFormat(fileDuration: 600, locale: russian)
        let time = try #require(format.time(from: "1:23,45"))
        #expect(abs(time - 83.45) < 1e-9)
    }

    @Test(arguments: ["", "abc", "1:2:3:4", "-5", "1:-2", "1::2", "1.5:20", "nan", "inf", "12,5"])
    func rejectsInvalidInput(_ text: String) {
        let format = TimeFormat(fileDuration: 600, locale: Locale(identifier: "en_US"))
        #expect(format.time(from: text) == nil)
    }

    @Test func roundTrips() throws {
        for locale in [english, russian] {
            let format = TimeFormat(fileDuration: 7200, locale: locale)
            let text = format.string(from: 4321.09)
            let parsed = try #require(format.time(from: text))
            #expect(abs(parsed - 4321.09) < 1e-6)
        }
    }
}
