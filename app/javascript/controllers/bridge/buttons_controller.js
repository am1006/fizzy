import { BridgeComponent } from "@hotwired/hotwire-native-bridge"
import { BridgeElement } from "@hotwired/hotwire-native-bridge"

export default class extends BridgeComponent {
  static component = "buttons"
  static targets = [ "button" ]

  connect() {
    super.connect()
    if (!this.hasButtonTarget) return
    this.notifyBridgeOfConnect()
  }

  disconnect() {
    super.disconnect()
    this.notifyBridgeOfDisconnect()
  }

  notifyBridgeOfConnect() {
    const buttons = this.buttonTargets.map((target, index) => {
      const element = new BridgeElement(target)
      return { ...element.getButton(), index }
    })

    this.send("connect", { buttons }, message => {
      this.activateButton(message)
    })
  }

  notifyBridgeOfDisconnect() {
    this.send("disconnect")
  }

  activateButton(message) {
    const selectedIndex = message.data.selectedIndex
    this.buttonTargets[selectedIndex].click()
  }
}
