import Foundation
import MultipeerConnectivity

class MultipeerManager: NSObject, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
  static let shared = MultipeerManager()
  var eventSink: FlutterEventSink?

  private let serviceType = "mpconn"
  private var peerID: MCPeerID!
  private var session: MCSession!
  private var advertiser: MCNearbyServiceAdvertiser!
  private var browser: MCNearbyServiceBrowser!

  private override init() {
    super.init()
    peerID = MCPeerID(displayName: UIDevice.current.name)
    session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    session.delegate = self
    advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
    advertiser.delegate = self
    browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
    browser.delegate = self
  }

  func startAdvertising(displayName: String) {
    stop()
    peerID = MCPeerID(displayName: displayName)
    session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
    session.delegate = self
    advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
    advertiser.delegate = self
    advertiser.startAdvertisingPeer()
    eventSink?(["event":"advertisingStarted"])
  }

  func stop() {
    advertiser?.stopAdvertisingPeer()
    browser?.stopBrowsingForPeers()
    session.disconnect()
    eventSink?(["event":"stopped"])
  }

  func startBrowsing() {
    browser.startBrowsingForPeers()
    eventSink?(["event":"browsingStarted"])
  }

  func sendDataToAll(data: Data) -> Bool {
    if session.connectedPeers.isEmpty { return false }
    do {
      try session.send(data, toPeers: session.connectedPeers, with: .reliable)
      return true
    } catch {
      eventSink?(["event":"error","message":"multipeer send failed: \(error.localizedDescription)"])
      return false
    }
  }

  func invitePeer(peerId: String) {
    // find peer by displayName among discovered peers and invite via browser? MCNearbyServiceBrowser doesn't give IDs same; here we only support auto invite via session
    eventSink?(["event":"info","message":"invitePeer not fully supported via id on Multipeer wrapper"])
  }

  // MARK: - Advertiser delegate
  func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    invitationHandler(true, session)
    eventSink?(["event":"invitationReceived","peerId":peerID.displayName,"displayName":peerID.displayName])
  }

  func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
    eventSink?(["event":"error","message":"advertiser failed: \(error.localizedDescription)"])
  }

  // MARK: - Browser delegate
  func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
    eventSink?(["event":"peerFound","peerId":peerID.displayName,"displayName":peerID.displayName])
  }
  func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    eventSink?(["event":"peerLost","peerId":peerID.displayName,"displayName":peerID.displayName])
  }
  func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
    eventSink?(["event":"error","message":"browser failed: \(error.localizedDescription)"])
  }

  // MARK: - Session delegate
  func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    switch state {
      case .connected: eventSink?(["event":"connectionState","peerId":peerID.displayName,"state":"connected"])
      case .notConnected: eventSink?(["event":"connectionState","peerId":peerID.displayName,"state":"notConnected"])
      case .connecting: break
    }
  }
  func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    let arr = Array(data)
    eventSink?(["event":"dataReceived","peerId":peerID.displayName,"data":arr])
  }
  // other session delegate methods (unused)
  func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
  func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
  func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
