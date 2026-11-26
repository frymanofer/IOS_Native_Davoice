import XCTest
@testable import CarAgent

// The car's confirmed replies: the same cases and expected sentences as the other car apps' car tool tests (all four apps must say the
// same thing for the same call).
final class CarToolsTests: XCTestCase {
    private func reply(_ name: String, _ args: JObj) -> (result: JObj, say: String) {
        guard case .reply(let r, let say) = CarTools.run(name, args) else {
            XCTFail("\(name): no sentence")
            return (JObj(), "")
        }
        return (asObj(r), say)
    }

    private func say(_ name: String, _ args: JObj) -> String { reply(name, args).say }
    private func result(_ name: String, _ args: JObj) -> JObj { reply(name, args).result }

    override func setUpWithError() throws {
        try TestSupport.load()
        Car.reset()
        Car.setDriving(false)
        Car.setSteering("left")
        CarTools.resetForTests()
        BasicLanguage.clearPending()
        AppLanguage.set("en")
    }

    func testTheH3dDemoProfileHasTheDualZoneTool() {
        XCTAssertTrue(CarTools.tools(wording: "h3d").contains { $0.name == "set_dual_zone_temperature" })
        XCTAssertFalse(CarTools.tools(wording: "v1").contains { $0.name == "set_dual_zone_temperature" })
        XCTAssertNotNil(CarTools.tools(wording: "h3d").first { $0.name == "unlock_car" }?.execution)
    }

    func testWindowsByPlaceEn() {
        XCTAssertEqual("I opened the front left window.", say("set_window", ["window": "front_left", "position": "open"]))
        XCTAssertEqual("open", Car.state.windows["front_left"])
        XCTAssertEqual("The front left window is already open.", say("set_window", ["window": "front_left", "position": "open"]))
        XCTAssertEqual("I opened the rear windows halfway.", say("set_window", ["window": "rear", "position": "half"]))
        XCTAssertEqual("I closed all the windows.", say("set_window", ["window": "all", "position": "close"]))
        XCTAssertEqual("All the windows are already closed.", say("set_window", ["window": "all", "position": "close"]))
    }

    func testWindowsByPlacePtBRAgreement() {
        AppLanguage.set("pt-BR")
        XCTAssertEqual("Abri o vidro traseiro direito.", say("set_window", ["window": "rear_right", "position": "open"]))
        XCTAssertEqual("O vidro traseiro direito já está aberto.", say("set_window", ["window": "rear_right", "position": "open"]))
        XCTAssertEqual("Os vidros do lado esquerdo já estão fechados.", say("set_window", ["window": "left", "position": "close"]))
        XCTAssertEqual("Deixei os vidros do lado esquerdo com uma fresta.", say("set_window", ["window": "left", "position": "crack"]))
        XCTAssertEqual("Fechei os vidros do lado esquerdo.", say("set_window", ["window": "left", "position": "close"]))
        XCTAssertEqual("Os vidros da frente já estão fechados.", say("set_window", ["window": "front", "position": "close"]))
    }

    func testDriverAndPassengerFollowTheSteeringWheel() {
        _ = say("set_window", ["window": "driver", "position": "open"])
        XCTAssertEqual("open", Car.state.windows["front_left"])
        Car.setSteering("right")
        _ = say("set_window", ["window": "driver", "position": "crack"])
        XCTAssertEqual("crack", Car.state.windows["front_right"])
        _ = say("set_window", ["window": "passenger", "position": "half"])
        XCTAssertEqual("half", Car.state.windows["front_left"])
    }

    func testBlockedWhileDrivingAndAnUnknownWindow() {
        Car.setDriving(true)
        let r = reply("set_window", ["window": "all", "position": "open"])
        XCTAssertEqual("I can't do that while the car is moving.", r.say)
        XCTAssertEqual(false, r.result["ok"])
        XCTAssertEqual("close", Car.state.windows["front_left"])
        XCTAssertEqual(false, result("set_window", ["window": "sunroof", "position": "open"])["ok"])
    }

    func testDoorsAndLocks() {
        XCTAssertEqual("I opened the rear left door.", say("open_door", ["door": "rear_left"]))
        XCTAssertEqual("The rear left door is already open.", say("open_door", ["door": "rear_left"]))
        AppLanguage.set("pt-BR")
        XCTAssertEqual("Fechei a porta traseira esquerda.", say("close_doors", ["door": "rear_left"]))
        XCTAssertEqual("Todas as portas já estão fechadas.", say("close_doors", [:]))
    }

    func testALockedDoorTheAppAsksNothingOpens() {
        _ = say("lock_car", [:])
        let r = reply("open_door", ["door": "all"])
        XCTAssertEqual("The car is locked. Should I unlock it?", r.say)
        XCTAssertEqual(false, r.result["ok"])
        XCTAssertTrue(Car.state.locked)
        XCTAssertTrue(Car.state.doors.values.allSatisfy { $0 == "closed" })
    }

    func testOneDoorLockedEnAndPt() {
        XCTAssertEqual("I locked the front right door.", say("lock_car", ["door": "front_right"]))
        XCTAssertFalse(Car.state.locked)
        XCTAssertEqual("The front right door is locked. Should I unlock it?", say("open_door", ["door": "passenger"]))
        AppLanguage.set("pt-BR")
        XCTAssertEqual("A porta dianteira direita já está trancada.", say("lock_car", ["door": "front_right"]))
        XCTAssertEqual("Destranquei a porta do passageiro.", say("unlock_car", ["door": "passenger"]))
        XCTAssertEqual("O carro já está destrancado.", say("unlock_car", [:]))
    }

    func testNoLockingWithADoorOpen() {
        _ = say("open_door", ["door": "front_left"])
        XCTAssertEqual("I can't lock it while the front left door is open. Close it first?", say("lock_car", [:]))
        XCTAssertFalse(Car.state.locked)
    }

    func testTemperatureOneZoneAndDualZone() {
        XCTAssertEqual("I set the driver's side to 22°C.", say("set_temperature", ["temperature": 22, "zone": "driver"]))
        XCTAssertEqual("The driver's side is already at 22°C.", say("set_temperature", ["temperature": 22, "zone": "driver"]))
        let r = reply("set_temperature", ["temperature": 40])
        XCTAssertEqual(false, r.result["ok"])
        XCTAssertEqual("I didn't change it: the temperature must be between 16 and 30.", r.say)
        XCTAssertEqual("I set the driver's side to 20°C and the passenger side to 23°C.", say("set_dual_zone_temperature", ["driver": 20, "passenger": 23]))
        XCTAssertEqual("The driver's side is already at 20°C and the passenger side at 23°C.", say("set_dual_zone_temperature", ["driver": 20, "passenger": 23]))
        AppLanguage.set("pt-BR")
        XCTAssertEqual("Coloquei o lado do motorista em 21°C, mas não o do passageiro: precisa ficar entre 16 e 30.",
                       say("set_dual_zone_temperature", ["driver": 21, "passenger": 35]))
        XCTAssertEqual("Não mudei a temperatura: os dois valores precisam ficar entre 16 e 30.", say("set_dual_zone_temperature", ["driver": 5, "passenger": 50]))
    }

    func testSeatDefrostVolume() {
        XCTAssertEqual("The heater in the driver's seat is already off.", say("set_seat_climate", ["feature": "heater", "level": "off"]))
        XCTAssertEqual("I set the heater in the driver's seat to medium.", say("set_seat_climate", ["feature": "heater", "level": "medium"]))
        XCTAssertEqual("The rear defogger is already off.", say("set_defrost", ["target": "rear", "on": false]))
        XCTAssertEqual("The sound is already on, volume 12.", say("set_volume", ["action": "unmute"]))
        XCTAssertEqual("I muted the sound.", say("set_volume", ["action": "mute"]))
    }

    func testVolumeStepsAndTargets() {
        let cases: [(JObj, String)] = [
            (["action": "up", "change": 5], "I turned the volume up to 17."),
            (["action": "down", "change": -2], "I turned the volume down to 15."),
            (["action": "down", "change": 4], "I turned the volume down to 11."),
            (["action": "set", "change": 3], "I turned the volume up to 14."),
            (["action": "up", "change": 50], "I turned the volume up to 30."),
            (["action": "set", "level": 12], "I set the volume to 12."),
            (["action": "up", "level": 2], "I turned the volume up to 14."),
            (["action": "down", "level": 20], "I turned the volume down to 0."),
            (["action": "set", "level": 12], "I set the volume to 12."),
            (["action": "down", "level": 5], "I turned the volume down to 5."),
            (["action": "up", "level": 20], "I turned the volume up to 20."),
            (["action": "up"], "I turned the volume up to 23."),
            (["action": "down"], "I turned the volume down to 20."),
            (["action": "set", "level": 12], "I set the volume to 12."),
        ]
        for (args, want) in cases { XCTAssertEqual(want, say("set_volume", args), Json.stringify(args)) }
    }

    func testFanLookupsETA() {
        AppLanguage.set("pt-BR")
        XCTAssertEqual("A ventilação já está no nível 3.", say("set_fan_speed", ["level": 3]))
        XCTAssertEqual("Coloquei a ventilação no nível 5.", say("set_fan_speed", ["level": 5]))
        XCTAssertEqual("A ventilação vai até o nível 7, então coloquei no nível 7.", say("set_fan_speed", ["level": 9]))
        XCTAssertEqual("A ventilação vai até o nível 7, e já está nele.", say("set_fan_speed", ["change": 2]))
        AppLanguage.set("en")
        XCTAssertEqual("The lowest fan level is 1, so I set it to level 1.", say("set_fan_speed", ["level": 0]))
        XCTAssertEqual("You have about 312 km of range left.", say("get_vehicle_status", ["item": "range"]))
        XCTAssertEqual("There's no active route. Where do you want to go?", say("get_trip_eta", [:]))
        _ = say("find_along_route", ["place_type": "gas_station"])
        _ = say("navigate_to", ["destination": "the nearest gas station"])
        XCTAssertEqual("You'll get to the nearest gas station in about 3 minutes, 2.1 km to go.", say("get_trip_eta", [:]))
        _ = say("navigate_to", ["destination": "airport"])
        XCTAssertEqual("You'll get to airport in about 24 minutes, 18 km to go.", say("get_trip_eta", [:]))
        AppLanguage.set("pt-BR")
        _ = say("find_along_route", ["place_type": "coffee"])
        _ = say("navigate_to", ["destination": "o café mais próximo"])
        XCTAssertEqual("Você chega em o café mais próximo em cerca de 3 minutos; faltam 2,1 km.", say("get_trip_eta", [:]))
    }

    func testAirflowWithTheArticleInPtBR() {
        AppLanguage.set("pt-BR")
        XCTAssertEqual("O ar agora vai para os pés.", say("set_airflow", ["mode": "feet"]))
        XCTAssertEqual("O ar já vai para os pés.", say("set_airflow", ["mode": "feet"]))
        XCTAssertEqual("O ar agora vai para o rosto e os pés.", say("set_airflow", ["mode": "face_and_feet"]))
    }

    func testPlayTheDriversWordsWhenTheModelCopiedTheTitleWrong() {
        CarTools.noteUserText("Play Pretty Woman")
        XCTAssertEqual("Playing Pretty Woman.", say("play_media", ["query": "Perma Woman"]))
    }

    private func compose(_ says: [(String, String, Bool)], _ text: String, _ lang: String = "en", acked: Bool = false) -> String {
        SpeechComposer.beginCarTurn()
        SpeechComposer.resetVariant()
        for (tool, said, merge) in says { SpeechComposer.noteCarSay(tool, said, merge) }
        return SpeechComposer.composeCarSpeech(text, SpeechComposer.carTurnActions(), lang, acked: acked)
    }

    func testSeveralActionsAreSaidAsOneSentence() {
        XCTAssertEqual("I closed all the doors and locked the car. Everything is secure.",
                       compose([("close_doors", "I closed all the doors.", true), ("lock_car", "I locked the car.", true)], "I closed all the doors. I locked the car."))
        XCTAssertEqual("I unlocked the car and opened all the doors. Come on in!",
                       compose([("unlock_car", "I unlocked the car.", true), ("open_door", "I opened all the doors.", true)], "I unlocked the car. I opened all the doors."))
        XCTAssertEqual("Fechei todas as janelas, fechei todas as portas e tranquei o carro. Agora o carro está todo seguro.",
                       compose([("set_window", "Fechei todas as janelas.", true), ("close_doors", "Fechei todas as portas.", true), ("lock_car", "Tranquei o carro.", true)],
                               "Fechei todas as janelas. Fechei todas as portas. Tranquei o carro.", "pt-BR"))
        XCTAssertEqual("I locked the car. You're good to go.", compose([("lock_car", "I locked the car.", true)], "I locked the car."))
        XCTAssertEqual("Destranquei todas as portas do carro. Pode entrar, o carro já está aberto.",
                       compose([("unlock_car", "Destranquei o carro.", true)], "Destranquei o carro.", "pt-BR"))
        // pt-BR: a short sentence said on its own is said longer (tested wording, as the RN example)
        XCTAssertEqual("Tranquei todas as portas do carro. Pode ficar tranquilo, está tudo seguro.",
                       compose([("lock_car", "Tranquei o carro.", true)], "Tranquei o carro.", "pt-BR"))
        XCTAssertEqual("Navigating home: about 24 minutes, 18 km. Let's go!",
                       compose([("navigate_to", "Navigating to home: about 24 minutes, 18 km.", true)], "Navigating to home: about 24 minutes, 18 km.", "en", acked: true))
    }

    func testABasicLanguageAsksFirstAPlainYesRunsIt() {
        AppLanguage.set("de")
        SpeechComposer.beginCarTurn()
        let asked = reply("set_window", ["window": "driver", "position": "open"])
        XCTAssertEqual(false, asked.result["ok"])
        XCTAssertEqual("close", Car.state.windows["front_left"])
        XCTAssertEqual("yes", BasicLanguage.normalizeYesNo("Ja", "de"))
        SpeechComposer.beginCarTurn()
        XCTAssertEqual(true, result("set_window", ["window": "driver", "position": "open"])["ok"])
        XCTAssertEqual("open", Car.state.windows["front_left"])
    }
}
