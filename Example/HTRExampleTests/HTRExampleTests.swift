//
//  HTRExampleTests.swift
//  HTRExampleTests
//
//  Created by Carl Brown on 11/16/23.
//

import XCTest
import HTTPTrafficReplayer
@testable import HTRExample

final class HTRExampleTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() async throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
        
        let urlConfig = URLSessionConfiguration.default
        var htrConfig = HTTPTrafficReplayerDefaultConfiguration()
        htrConfig.behavior = .logOnly
        HTTPTrafficReplayer.configuration = htrConfig
        URLProtocol.registerClass(HTTPTrafficReplayer.self)
        var protocolClasses = urlConfig.protocolClasses ?? [AnyClass]()
        protocolClasses.insert(HTTPTrafficReplayer.self, at: 0)
        urlConfig.protocolClasses = protocolClasses
        let session = URLSession(configuration: urlConfig)
        let pointURL = URL(string: "https://api.weather.gov/points/39.7456%2C-97.0892")!
        var pointReq = URLRequest(url: pointURL)
        pointReq.setValue("HTRExampleTest v 1.0", forHTTPHeaderField: "User-Agent")
        pointReq.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        let (pointData, pointResponse) = try await session.data(for: pointReq)
        XCTAssertNotNil(pointData)
        let pointHTTPResponse = try XCTUnwrap(pointResponse as? HTTPURLResponse)
        XCTAssertEqual(pointHTTPResponse.statusCode, 200)
        let point = try JSONDecoder().decode(PointInfo.self, from: pointData)
        XCTAssertNotNil(point)
        
        let forecastURL = URL(string: "https://api.weather.gov/gridpoints/\(point.properties.gridId)/\(point.properties.gridX)%2C\(point.properties.gridY)/forecast")!
        var forecastReq = URLRequest(url: forecastURL)
        forecastReq.setValue("HTRExampleTest v 1.0", forHTTPHeaderField: "User-Agent")
        forecastReq.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        let (forecastData, forecastResponse) = try await session.data(for: forecastReq)
        XCTAssertNotNil(forecastData)
        let forecastHTTPResponse = try XCTUnwrap(forecastResponse as? HTTPURLResponse)
        XCTAssertEqual(forecastHTTPResponse.statusCode, 200)
        let forecast = try JSONDecoder().decode(ForecastInfo.self, from: forecastData)
        XCTAssertNotNil(forecast)
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }

}
