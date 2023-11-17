//
//  PointInfo.swift
//  HTRExample
//
//  Created by Carl Brown on 11/16/23.
//

import Foundation

struct PointInfo: Codable, Identifiable {
    let id: String
    let type: String
    let properties: Properties
    
    
    
    struct Properties: Codable, Identifiable {
        let id: String
        let forecastOffice: String
        let timeZone: String
        let radarStation: String
        let gridId: String
        let gridX: Int
        let gridY: Int

        enum CodingKeys: String, CodingKey {
            case id = "@id", forecastOffice, timeZone, radarStation, gridId, gridX, gridY
        }
    }
}
