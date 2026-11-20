// Liaison Bluetooth avec le M5 (rôle central). Fonctionne en arrière-plan grâce au mode
// « bluetooth-central » et à la restauration d'état : iOS relance l'app si le M5 réapparaît.
import CoreBluetooth
import Foundation
import Observation

@MainActor
@Observable
final class BLELink: NSObject {
    enum State: Equatable {
        case bluetoothOff
        case unauthorized
        case searching
        case connecting
        case pairing        // en attente du code affiché sur le M5
        case connected
    }

    private(set) var state: State = .bluetoothOff
    private(set) var status: DeviceStatus?
    /// Message d'aide affiché quand quelque chose bloque (appairage refusé, etc.).
    private(set) var problem: String?

    /// Appelé pour chaque notification DATA décodée.
    @ObservationIgnored var onRecords: (([Record]) -> Void)?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var dataChr: CBCharacteristic?
    @ObservationIgnored private var cmdChr: CBCharacteristic?
    @ObservationIgnored private var statusChr: CBCharacteristic?

    private static let restoreID = "com.hector.M5Radar.central"
    private static let savedKey = "m5.peripheral"

    var isReady: Bool { state == .connected && cmdChr != nil }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreID,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    /// Envoie une commande au M5. Renvoie false si la liaison n'est pas prête.
    @discardableResult
    func send(_ command: Proto.Command) -> Bool {
        guard isReady, let peripheral, let cmdChr else { return false }
        peripheral.writeValue(command.bytes, for: cmdChr, type: .withResponse)
        return true
    }

    /// Oublie le M5 mémorisé (par exemple après un changement de carte).
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        reset()
        peripheral = nil
        connectOrSearch()
    }

    // MARK: - Interne

    private func reset() {
        dataChr = nil
        cmdChr = nil
        statusChr = nil
        status = nil
    }

    private func connectOrSearch() {
        guard let central, central.state == .poweredOn else { return }
        if peripheral == nil,
           let s = UserDefaults.standard.string(forKey: Self.savedKey), let id = UUID(uuidString: s) {
            peripheral = central.retrievePeripherals(withIdentifiers: [id]).first
        }
        if let peripheral {
            peripheral.delegate = self
            switch peripheral.state {
            case .connected:
                state = .connecting
                peripheral.discoverServices([Proto.service])
            case .connecting:
                state = .connecting
            default:
                // Connexion « en attente » : sans délai d'expiration, iOS la conclut dès que
                // le M5 est à portée, même app en arrière-plan.
                central.connect(peripheral)
                state = .searching
            }
        } else {
            state = .searching
        }
        // On scanne aussi, au cas où l'identifiant mémorisé ne serait plus valable.
        if state == .searching, !central.isScanning {
            central.scanForPeripherals(withServices: [Proto.service])
        }
    }

    private func handleData(_ value: Data) {
        let records = RecordDecoder.decode(value)
        if !records.isEmpty { onRecords?(records) }
    }

    private func explain(_ error: Error) {
        if let cb = error as? CBError, cb.code == .peerRemovedPairingInformation {
            problem = "Le M5 a oublié l'appairage. Dans Réglages > Bluetooth, touche (i) à côté de M5Radar puis « Oublier cet appareil », et reviens ici."
        } else if let att = error as? CBATTError,
                  att.code == .insufficientAuthentication || att.code == .insufficientEncryption {
            problem = "Appairage refusé ou code erroné. Le code à saisir s'affiche sur l'écran du M5."
        } else {
            problem = error.localizedDescription
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLELink: @preconcurrency CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = restored
            restored.delegate = self
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            problem = nil
            connectOrSearch()
        case .unauthorized:
            state = .unauthorized
        default:
            state = .bluetoothOff
            reset()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Le M5 annonce notre UUID de service ; le premier trouvé est le bon.
        central.stopScan()
        if let current = self.peripheral, current.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(current)
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        central.stopScan()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedKey)
        state = .connecting
        peripheral.discoverServices([Proto.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let error { explain(error) }
        reset()
        connectOrSearch()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if let error, (error as? CBError)?.code != .peripheralDisconnected,
           (error as? CBError)?.code != .connectionTimeout {
            explain(error)
        }
        reset()
        connectOrSearch()
    }
}

// MARK: - CBPeripheralDelegate

extension BLELink: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Proto.service }) else {
            if let error { explain(error) }
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Proto.data, Proto.cmd, Proto.status], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Proto.data: dataChr = c
            case Proto.cmd: cmdChr = c
            case Proto.status: statusChr = c
            default: break
            }
        }
        guard let dataChr, cmdChr != nil, let statusChr else {
            problem = "Le M5 ne présente pas le service attendu (firmware différent ?)."
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        // DATA est chiffrée et authentifiée : l'abonnement déclenche l'appairage
        // (iOS demande le code à 6 chiffres affiché sur le M5).
        state = .pairing
        peripheral.setNotifyValue(true, for: dataChr)
        peripheral.setNotifyValue(true, for: statusChr)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            explain(error)
            return
        }
        guard characteristic.uuid == Proto.data, characteristic.isNotifying else { return }
        // Liaison sécurisée et abonnée : le M5 commence à vider son tampon.
        problem = nil
        state = .connected
        send(.setTime(Date()))
        if let statusChr { peripheral.readValue(for: statusChr) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case Proto.data:
            handleData(value)
        case Proto.status:
            if let s = DeviceStatus(value) { status = s }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { explain(error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        reset()
        peripheral.discoverServices([Proto.service])
    }
}
