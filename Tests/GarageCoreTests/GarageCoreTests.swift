import XCTest
@testable import GarageCore

final class GarageCoreTests: XCTestCase {
    func testPlateNormalizationAndRejection() throws {
        XCTAssertEqual(try Plates.normalize("РВ 1234 АВ"), "PB1234AB")
        XCTAssertThrowsError(try Plates.normalize("../wrong"))
    }
    func testDateValidationAndStorageRejectCorruptData() throws {
        XCTAssertNil(LocalDay("2027-02-31"))
        XCTAssertNotNil(LocalDay("2028-02-29"))
        XCTAssertThrowsError(try JSONDecoder().decode(LocalDay.self, from: Data("\"2027-02-31\"".utf8)))
    }
    func testProviderFailureIsNotMissingVignette() {
        XCTAssertThrowsError(try Responses.vignette(Data("{\"ok\":false,\"status\":{\"code\":500}}".utf8), plate: "CA1234AB"))
    }
    func testWrongCarIsNeverSaved() {
        let json = #"{"ok":true,"vignette":{"licensePlateNumber":"CA9999AB","validityDateTo":"2027-01-15T23:59:59","statusBoolean":true}}"#
        XCTAssertThrowsError(try Responses.vignette(Data(json.utf8), plate: "CA1234AB"))
    }
    func testInsuranceRequiresConfirmedDate() {
        let json = #"{"ok":true,"plate":"CA1234AB","found":true,"policies":[{"dateTo":"unknown"}]}"#
        XCTAssertThrowsError(try Responses.insurance(Data(json.utf8), plate: "CA1234AB"))
    }
    func testInsuranceAndInspectionSuccess() throws {
        let json = #"{"ok":true,"plate":"CA1234AB","found":true,"policies":[{"dateTo":"15.01.2027г. 23:59:59ч."}]}"#
        XCTAssertEqual(try Responses.insurance(Data(json.utf8), plate: "CA1234AB").validTo?.iso, "2027-01-15")
        let text = "Валиден ГТП\nCA1234AB\nСрок за следващ преглед\n12.01.2027"
        XCTAssertEqual(try Responses.inspection(text, plate: "CA1234AB").validTo?.iso, "2027-01-12")
    }
    func testRemindersUseSofiaNineAMAcrossDSTAndSkipPast() throws {
        var car = Car(plate: "CA1234AB")
        car.apply(Deadline(kind: .inspection, validTo: LocalDay("2027-04-02"), status: "valid"))
        let now = ISO8601DateFormatter().date(from: "2027-03-01T00:00:00Z")!
        let plans = ReminderPlanner.plan(cars: [car], now: now)
        XCTAssertEqual(plans.count, 4)
        for p in plans { XCTAssertEqual(LocalDay.calendar.component(.hour, from: p.fireAt), 9); XCTAssertGreaterThan(p.fireAt, now) }
        XCTAssertEqual(ReminderPlanner.plan(cars: [car], now: LocalDay("2027-04-03")!.date).count, 0)
    }
    func testReminderLimitChoosesSoonestAndIdentifiersAreStable() {
        var cars = (1...10).map { Car(plate: String(format: "CA%04dAB", $0)) }
        for i in cars.indices { for kind in DeadlineKind.allCases { cars[i].apply(Deadline(kind: kind, validTo: LocalDay("2027-05-01"), status: "valid")) } }
        let now = LocalDay("2027-01-01")!.date
        let plan = ReminderPlanner.plan(cars: cars, now: now)
        XCTAssertEqual(plan.count, 60)
        XCTAssertEqual(plan.map(\.id), ReminderPlanner.plan(cars: cars, now: now).map(\.id))
        XCTAssertEqual(Set(plan.map(\.id)).count, plan.count)
    }
}
