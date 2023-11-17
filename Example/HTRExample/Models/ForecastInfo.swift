//
//  ForecastInfo.swift
//  HTRExample
//
//  Created by Carl Brown on 11/16/23.
//

import Foundation

struct ForecastInfo: Codable {
    let type: String
    let properties: Properties
    
    struct Properties: Codable {
        let generatedAt: String
        let updateTime: String
        let periods: [Period]
        
        struct Period: Codable {
            let number: Int
            let name: String
            let startTime: String
            let endTime: String
            let isDaytime: Bool
            let temperature: Float
            let temperatureUnit: String
            let windDirection: String
            let shortForecast: String
            let detailedForecast: String
            let probabilityOfPrecipitation: ProbabilityOfPrecipitation
            
            struct ProbabilityOfPrecipitation: Codable {
                let value: Float?
                let unitCode: String
            }
        }
    }
}
