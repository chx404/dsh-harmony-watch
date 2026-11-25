import socket from '@ohos.net.socket';
import connection from '@ohos.net.connection';
import cryptoFramework from '@ohos.security.cryptoFramework';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { DirectApiConfig, validateDirectConfig } from './DirectApi';
import { PhoneApiConfig, WatchHttpParser, WatchHttpReply, WatchProvisionProtocol } from './WatchProvisionProtocol';

export interface WatchProvisionLink {
  url: string;
  expiresAt: number;
}

class WatchProvisionPeer {
  client: socket.TCPSocketConnection;
  parser: WatchHttpParser = new WatchHttpParser();
  timer: number = -1;
  replied: boolean = false;
  constructor(client: socket.TCPSocketConnection) { this.client = client; }
}

// Only a Wi-Fi interface is used; never advertise cellular, VPN or a DSH host address.
export function isWatchLanIPv4(address: string): boolean {
  const parts: string[] = address.split('.');
  if (parts.length !== 4) { return false; }
  for (let i: number = 0; i < parts.length; i++) {
    if (!/^\d{1,3}$/.test(parts[i]) || Number(parts[i]) > 255) { return false; }
  }
  const a: number = Number(parts[0]);
  const b: number = Number(parts[1]);
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}

/** A temporary server ON THE WATCH. No DSH API, token, host or cloud relay is involved. */
export class WatchProvisionService {
  private server?: socket.TCPSocketServer;
  private protocol?: WatchProvisionProtocol;
  private peers: Map<number, WatchProvisionPeer> = new Map();
  private epoch: number = 0;
  private expiry: number = -1;
  private networkTimer: number = -1;
  private networkCheck: boolean = false;
  private onConfig: (config: DirectApiConfig) => void;
  private onNotice: (notice: string) => void;

  constructor(onConfig: (config: DirectApiConfig) => void, onNotice: (notice: string) => void) {
    this.onConfig = onConfig;
    this.onNotice = onNotice;
  }

  private async wifiAddress(): Promise<string> {
    const nets: connection.NetHandle[] = await connection.getAllNets();
    for (let i: number = 0; i < nets.length; i++) {
      try {
        const caps: connection.NetCapabilities = await connection.getNetCapabilities(nets[i]);
        if (caps.bearerTypes.indexOf(connection.NetBearType.BEARER_WIFI) < 0) { continue; }
        const props: connection.ConnectionProperties = await connection.getConnectionProperties(nets[i]);
        for (let j: number = 0; j < props.linkAddresses.length; j++) {
          const address: string = props.linkAddresses[j].address.address;
          if (isWatchLanIPv4(address)) { return address; }
        }
      } catch (_) { /* A stale network handle must not hide a working Wi-Fi network. */ }
    }
    throw new Error('请先让手表连接 Wi-Fi，手机也连接同一 Wi-Fi，再重新生成二维码');
  }

  async start(): Promise<WatchProvisionLink> {
    this.stop();
    const epoch: number = this.epoch;
    let server: socket.TCPSocketServer | undefined = undefined;
    try {
      const address: string = await this.wifiAddress();
      if (epoch !== this.epoch) { throw new Error('扫码已取消'); }
      server = socket.constructTCPSocketServerInstance();
      this.server = server;
      server.on('connect', (client: socket.TCPSocketConnection) => { this.accept(client, epoch); });
      server.on('error', () => {
        if (epoch !== this.epoch) { return; }
        this.stop(); this.onNotice('手表临时配置服务已中断，请重试；不需要 DSH 宿主');
      });
      await server.listen({ address: address, family: 1, port: 0 });
      if (epoch !== this.epoch) {
        await server.close().catch(() => {});
        throw new Error('扫码已取消');
      }
      const local: socket.NetAddress = await server.getLocalAddress();
      if (epoch !== this.epoch) { throw new Error('扫码已取消'); }
      if (!local.port || local.port < 1) { throw new Error('无法取得手表配置端口，请重试'); }
      const entropy: Uint8Array = cryptoFramework.createRandom().generateRandomSync(32).data;
      const ticket: string = new util.Base64Helper().encodeToStringSync(entropy)
        .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      entropy.fill(0);
      const origin: string = 'http://' + address + ':' + local.port.toString();
      const expiresAt: number = Date.now() + 300000;
      this.protocol = new WatchProvisionProtocol(ticket, origin, expiresAt,
        (config: PhoneApiConfig): PhoneApiConfig => {
          const checked: DirectApiConfig = validateDirectConfig({ baseUrl: config.baseUrl,
            model: config.model, apiKey: config.apiKey, protocol: config.protocol });
          return { baseUrl: checked.baseUrl, model: checked.model, apiKey: checked.apiKey, protocol: checked.protocol };
        });
      this.expiry = setTimeout(() => {
        if (epoch !== this.epoch) { return; }
        this.stop(); this.onNotice('二维码已过期，临时端口已关闭，请重新生成');
      }, 300000);
      this.networkTimer = setInterval(() => { this.checkNetwork(address, epoch); }, 5000);
      return { url: origin + '/#' + ticket, expiresAt: expiresAt };
    } catch (error) {
      // A late result must not close a newly-created service instance.
      if (epoch === this.epoch) { this.stop(); }
      if (server) { server.close().catch(() => {}); }
      const message: string = (error as Error).message || '';
      if (message.indexOf('Wi-Fi') >= 0 || message === '扫码已取消' || message.indexOf('端口') >= 0) {
        throw new Error(message);
      }
      const code: number = (error as BusinessError).code;
      throw new Error('无法开启手表配置服务' + (code ? '（错误 ' + code.toString() + '）' : '') + '；请确认手表 Wi-Fi 与网络权限');
    }
  }

  private async checkNetwork(address: string, epoch: number): Promise<void> {
    if (epoch !== this.epoch || this.networkCheck) { return; }
    this.networkCheck = true;
    try {
      const current: string = await this.wifiAddress();
      if (epoch === this.epoch && current !== address) {
        this.stop(); this.onNotice('手表 Wi-Fi 地址已变化，请重新生成二维码');
      }
    } catch (_) {
      if (epoch === this.epoch) {
        this.stop(); this.onNotice('手表 Wi-Fi 已断开，临时端口已关闭，请连接后重试');
      }
    } finally { this.networkCheck = false; }
  }

  private accept(client: socket.TCPSocketConnection, epoch: number): void {
    if (epoch !== this.epoch || !this.protocol || this.peers.size >= 4) {
      client.close().catch(() => {}); return;
    }
    const peer = new WatchProvisionPeer(client);
    this.peers.set(client.clientId, peer);
    peer.timer = setTimeout(() => { this.closePeer(peer); }, 8000);
    client.on('close', () => { this.releasePeer(peer); });
    client.on('error', () => { this.closePeer(peer); });
    client.on('message', (message: socket.SocketMessageInfo) => {
      if (peer.replied || epoch !== this.epoch || !this.protocol) { return; }
      try {
        const request = peer.parser.push(new Uint8Array(message.message));
        if (!request) { return; }
        peer.replied = true;
        const reply: WatchHttpReply = this.protocol.handle(request);
        const config: PhoneApiConfig | undefined = this.protocol.takeConfig();
        this.respond(peer, reply, config, epoch);
      } catch (_) {
        peer.replied = true;
        this.respond(peer, { status: 400, body: '{"ok":false,"error":"请求格式无效或过大"}',
          contentType: 'application/json; charset=utf-8' }, undefined, epoch);
      }
    });
  }

  private async respond(peer: WatchProvisionPeer, reply: WatchHttpReply,
    config: PhoneApiConfig | undefined, epoch: number): Promise<void> {
    const body: Uint8Array = new util.TextEncoder().encodeInto(reply.body);
    const head: string = 'HTTP/1.1 ' + reply.status.toString() + ' Response\r\n' +
      'Content-Type: ' + reply.contentType + '\r\n' +
      'Content-Length: ' + body.length.toString() + '\r\n' +
      'Connection: close\r\nCache-Control: no-store, max-age=0\r\nPragma: no-cache\r\n' +
      'Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n' +
      "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n\r\n";
    const header: Uint8Array = new util.TextEncoder().encodeInto(head);
    const data = new Uint8Array(header.length + body.length);
    data.set(header); data.set(body, header.length);
    try { await peer.client.send({ data: data.buffer as ArrayBuffer }); } catch (_) {}
    finally {
      this.closePeer(peer);
      // Submission is delivered for review even if the phone missed its acknowledgement.
      // Never execute API requests or persist credentials here.
      if (config && epoch === this.epoch) {
        this.stop(); this.onConfig({ baseUrl: config.baseUrl, model: config.model,
          apiKey: config.apiKey, protocol: config.protocol });
      }
    }
  }

  private releasePeer(peer: WatchProvisionPeer): void {
    if (peer.timer >= 0) { clearTimeout(peer.timer); peer.timer = -1; }
    this.peers.delete(peer.client.clientId);
  }

  private closePeer(peer: WatchProvisionPeer): void {
    peer.replied = true;
    this.releasePeer(peer);
    try { peer.client.off('message'); peer.client.off('close'); peer.client.off('error'); } catch (_) {}
    peer.client.close().catch(() => {});
  }

  stop(): void {
    this.epoch++;
    if (this.expiry >= 0) { clearTimeout(this.expiry); this.expiry = -1; }
    if (this.networkTimer >= 0) { clearInterval(this.networkTimer); this.networkTimer = -1; }
    const peers: WatchProvisionPeer[] = Array.from(this.peers.values());
    for (let i: number = 0; i < peers.length; i++) { this.closePeer(peers[i]); }
    this.peers.clear();
    this.protocol?.dispose(); this.protocol = undefined;
    const server = this.server; this.server = undefined;
    if (server) {
      try { server.off('connect'); server.off('error'); } catch (_) {}
      server.close().catch(() => {});
    }
  }
}
