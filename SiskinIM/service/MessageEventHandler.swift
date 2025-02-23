//
// MessageEventHandler.swift
//
// Siskin IM
// Copyright (C) 2019 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see https://www.gnu.org/licenses/.
//

import Foundation
import TigaseSwift
import TigaseSwiftOMEMO
import os
import Combine
import TigaseLogging

class MessageEventHandler: XmppServiceEventHandler {
    
    public static let instance = MessageEventHandler();
    
    public static let OMEMO_AVAILABILITY_CHANGED = Notification.Name(rawValue: "OMEMOAvailabilityChanged");
    
    public static let eventsPublisher = PassthroughSubject<SyncEvent,Never>();
    
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MessageEventHandler");
    
    enum SyncEvent {
        case started(account: BareJID, with: BareJID?)
        case finished(account: BareJID, with: BareJID?)
    }
    
    static func prepareBody(message: Message, forAccount account: BareJID) -> (String?, MessageEncryption, String?) {
        var encryption: MessageEncryption = .none;
        var fingerprint: String? = nil;
        
        guard (message.type ?? .chat) != .error else {
            guard let body = message.body else {
                if let delivery = message.messageDelivery {
                    switch delivery {
                    case .received(_):
                        // if our message delivery confirmation is not delivered just drop this info
                        return (nil, encryption, nil);
                    default:
                        break;
                    }
                }
                return (message.to?.resource == nil ? nil : "", encryption, nil);
            }
            return (body, encryption, nil);
        }
        
        var encryptionErrorBody: String?;
        if var from = message.from?.bareJid, let context = XmppService.instance.getClient(for: account) {
            if message.type == .groupchat, let nickname = message.from?.resource, let occupantJid = DBChatStore.instance.room(for: context, with: from)?.occupant(nickname: nickname)?.jid {
                from = occupantJid.bareJid;
            }
            switch context.module(.omemo).decode(message: message, from: from) {
            case .successMessage(_, let keyFingerprint):
                encryption = .decrypted;
                fingerprint = keyFingerprint
                break;
            case .successTransportKey(_, _):
                logger.debug("got transport key with key and iv!");
            case .failure(let error):
                switch error {
                case .invalidMessage:
                    encryptionErrorBody = NSLocalizedString("Message was not encrypted for this device.", comment: "message decryption error");
                    encryption = .notForThisDevice;
                case .duplicateMessage:
                    // message is a duplicate and was processed before
                    return (nil, .none, nil);
                case .notEncrypted:
                    encryption = .none;
                default:
                    encryptionErrorBody = NSLocalizedString("Message decryption failed!", comment: "message decryption error");
                    encryption = .decryptionFailed;
                }
                break;
            }
        }

        guard let body = message.body ?? message.oob ?? encryptionErrorBody else {
            return (nil, encryption, nil);
        }
        return (body, encryption, fingerprint);
    }
    
    let events: [Event] = [OMEMOModule.AvailabilityChangedEvent.TYPE];
    
    private var cancellables: Set<AnyCancellable> = [];
    
    init() {
        DBChatHistoryStore.instance.markedAsRead.sink(receiveValue: { [weak self] marked in
            self?.sendDisplayed(marked);
        }).store(in: &cancellables);
        MessageEventHandler.eventsPublisher.receive(on: MessageEventHandler.syncSinceQueue).sink(receiveValue: { [weak self] event in
            self?.syncStateChanged(event);
        }).store(in: &cancellables);
    }
    
    func register(for client: XMPPClient, cancellables: inout Set<AnyCancellable>) {
        let account = client.userBareJid;
        client.$state.sink(receiveValue: { [weak client] state in
            guard case .connected(let resumed) = state, !resumed, let client = client else {
                return;
            }
            MessageEventHandler.scheduleMessageSync(for: client.userBareJid);
            DBChatHistoryStore.instance.loadUnsentMessage(for: client.userBareJid, completionHandler: { (account, messages) in
                DispatchQueue.global(qos: .background).async {
                    for message in messages {
                        var chat = DBChatStore.instance.conversation(for: account, with: message.jid);
                        if chat == nil {
                            switch DBChatStore.instance.createChat(for: client, with: message.jid) {
                            case .created(let newChat):
                                chat = newChat;
                            case .found(let existingChat):
                                chat = existingChat;
                            case .none:
                                return;
                            }
                        }
                        if let dbChat = chat as? Chat {
                            dbChat.resendMessage(content: message.data, isAttachment: message.type == .attachment, encryption: message.encryption != .none ? .omemo : .none, stanzaId: message.correctionStanzaId ?? message.stanzaId, correctedMessageOriginId: message.correctionStanzaId == nil ? nil : message.stanzaId);
                        }

                    }
                }
            });
        }).store(in: &cancellables);
        client.module(.message).messagesPublisher.sink(receiveValue: { e in
            DBChatHistoryStore.instance.append(for: e.chat as! Chat, message: e.message, source: .stream);
        }).store(in: &cancellables);
        client.module(.messageDeliveryReceipts).receiptsPublisher.sink(receiveValue: { receipt in
            guard let conversation = MessageEventHandler.conversationKey(for: receipt.message, on: account) else {
                return;
            }
            DBChatHistoryStore.instance.updateItemState(for: conversation, stanzaId: receipt.messageId, from: .outgoing(.sent), to: .outgoing(.delivered));
        }).store(in: &cancellables);
        client.context.module(.chatMarkers).markersPublisher.sink(receiveValue: { marker in
            guard let conversation = MessageEventHandler.conversationKey(for: marker.message, on: account), let sender = marker.message.from else {
                return;
            }

            let type = ChatMarker.MarkerType.from(chatMarkers: marker.marker);
            if let idx = sender.localPart?.firstIndex(of: "#"), let localPart = sender.localPart {
                let participantId = String(localPart[localPart.startIndex..<idx]);
                let afterIdx = localPart.index(after: idx);
                if afterIdx != localPart.endIndex {
                    let channelLocalPart = String(localPart[afterIdx..<localPart.endIndex]);
                    if let channel = DBChatStore.instance.conversation(for: account, with: BareJID(localPart: channelLocalPart, domain: sender.domain)) as? Channel, channel.participantId == participantId, let nickname = channel.nickname {
                        DBChatMarkersStore.instance.mark(conversation: conversation, before: marker.marker.id, as: type, by: .participant(id: participantId, nickname: nickname, jid: account))
                    }
                    return;
                }
            }
            
            switch conversation {
            case is Chat:
                DBChatMarkersStore.instance.mark(conversation: conversation, before: marker.marker.id, as: type, by: sender.bareJid == account ? .me(conversation: conversation) : .buddy(conversation: conversation));
            case is Room:
                if let nickname = sender.resource, sender.bareJid != conversation.account {
                    DBChatMarkersStore.instance.mark(conversation: conversation, before: marker.marker.id, as: type, by: .occupant(nickname: nickname, jid: nil));
                }
            case is Channel:
                if let mix = marker.message.mix, let id = sender.resource, let nickname = mix.nickname {
                    DBChatMarkersStore.instance.mark(conversation: conversation, before: marker.marker.id, as: type, by: .participant(id: id, nickname: nickname, jid: mix.jid));
                }
            default:
                break;
            }
        }).store(in: &cancellables);
        client.module(.messageCarbons).carbonsPublisher.sink(receiveValue: { carbon in
            let conversation: ConversationKey = DBChatStore.instance.conversation(for: account, with: carbon.jid.bareJid) ?? ConversationKeyItem(account: account, jid: carbon.jid.bareJid);
                        
            DBChatHistoryStore.instance.append(for: conversation, message: carbon.message, source: .carbons(action: carbon.action));
        }).store(in: &cancellables);
        client.module(.mam).$availableVersions.sink(receiveValue: { [weak client] versions in
            guard !versions.isEmpty, let client = client else {
                return;
            }
            MessageEventHandler.syncMessagesScheduled(for: client);
        }).store(in: &cancellables);
        client.module(.mam).archivedMessagesPublisher.sink(receiveValue: { archived in
            guard let conversation = MessageEventHandler.conversationKey(for: archived.message, on: account) else {
                return;
            }
            DBChatHistoryStore.instance.append(for: conversation, message: archived.message, source: .archive(source: archived.source, version: archived.query.version, messageId: archived.messageId, timestamp: archived.timestamp));
        }).store(in: &cancellables);
        client.module(.messageCarbons).$isAvailable.filter({ $0 }).sink(receiveValue: { [weak client] _ in
            client?.module(.messageCarbons).enable();
        }).store(in: &cancellables);
    }
 
    func handle(event: Event) {
        switch event {
        case let e as OMEMOModule.AvailabilityChangedEvent:
            NotificationCenter.default.post(name: MessageEventHandler.OMEMO_AVAILABILITY_CHANGED, object: e);
        default:
            break;
        }
    }
    
    func sendDisplayed(_ marked: DBChatHistoryStore.MarkedAsRead) {
        guard let lastMarkable = marked.messages.last(where: { $0.markableId != nil }), let stanzaId = lastMarkable.markableId else {
            return;
        }
            
        // maybe we should enqueue displayed as well?
        DBChatStore.instance.conversation(for: marked.account, with: marked.jid)?.sendChatMarker(.displayed(id: stanzaId), andDeliveryReceipt: false);
    }
        
    private struct ReadMarkersKey: Hashable {
        let account: BareJID;
        let jid: BareJID?;
    }

    private class ReadMarkersQueue {
        private var queue: [Item] = [];
            
        func add(for conversation: ConversationKey, timestamp: Date, stanzaId: String) {
            if let idx = queue.firstIndex(where: { $0.conversation.account == conversation.account && $0.conversation.jid == $0.conversation.jid }) {
                guard queue[idx].timestamp <= timestamp else {
                    return;
                }
                queue.remove(at: idx);
            }
            queue.append(Item(conversation: conversation, timestamp: timestamp, stanzaId: stanzaId));
        }
            
        func sendQueued() {
            for item in queue {
                (item.conversation as? Conversation)?.sendChatMarker(.received(id: item.stanzaId), andDeliveryReceipt: false);
            }
        }
            
        func cancelReceived(for conversation: ConversationKey, before: Date) {
            queue = queue.filter({ $0.conversation.account != conversation.account || $0.conversation.jid != conversation.jid || $0.timestamp >= before });
        }
            
        struct Item {
            let conversation: ConversationKey;
            let timestamp: Date;
            let stanzaId: String;
        }
    }
        
    private var readMarkersToSendQueue: [ReadMarkersKey: ReadMarkersQueue] = [:];
        
    enum ReceiptType {
        case deliveryReceipt
        case chatMarker
    }
    
    func sendReceived(for conversation: ConversationKey, timestamp: Date, stanzaId: String, receipts: [ReceiptType]) {
        guard !receipts.isEmpty, let conv = (conversation as? Conversation) ?? DBChatStore.instance.conversation(for: conversation.account,    with: conversation.jid) else {
            return;
        }

        if receipts.contains(.chatMarker) {
            if let queue = readMarkersToSendQueue[.init(account: conv.account, jid: conv.jid)] ?? readMarkersToSendQueue[.init(account: conv.account, jid: nil)] {
                queue.add(for: conv, timestamp: timestamp, stanzaId: stanzaId);
            } else {
                conv.sendChatMarker(.received(id: stanzaId), andDeliveryReceipt: receipts.contains(.deliveryReceipt));
            }
        } else if receipts.contains(.deliveryReceipt) {
            conv.context?.module(.messageDeliveryReceipts).sendReceived(to: JID(conversation.jid), forStanzaId: stanzaId, type: .chat);
        }
    }
        
    func cancelReceived(for conv: ConversationKey, before: Date) {
        guard let queue = readMarkersToSendQueue[.init(account: conv.account, jid: conv.jid)] ?? readMarkersToSendQueue[.init(account: conv.account, jid: nil)] else {
            return;
        }
        queue.cancelReceived(for: conv, before: before);
    }
        
    private func syncStateChanged(_ event: SyncEvent) {
        switch event {
        case .started(let account, let jid):
            readMarkersToSendQueue[.init(account: account, jid: jid)] = ReadMarkersQueue();
        case .finished(let account, let jid):
            readMarkersToSendQueue.removeValue(forKey: .init(account: account, jid: jid))?.sendQueued();
        }
    }
        
    static func conversationKey(for message: Message, on account: BareJID) -> ConversationKey? {
        guard let from = message.from?.bareJid, let to = message.to?.bareJid else {
            return nil;
        }
        
        let jid = account != from ? from : to;
        
        return DBChatStore.instance.conversation(for: account, with: jid) ?? ConversationKeyItem(account: account, jid: jid);
    }
    
    static func calculateDirection(for conversation: ConversationKey, direction: MessageDirection, sender: ConversationEntrySender) -> MessageDirection {
        switch sender {
        case .none:
            assert(false, "Cannot calculate direction for sender `.none`")
            return .outgoing;
        case .me(_):
            return .outgoing;
        case .buddy(_):
            return .incoming;
        case .participant(let id, _, let jid):
            if let senderJid = jid {
                return senderJid == conversation.account ? .outgoing : .incoming;
            }
            if let channel = conversation as? Channel {
                return channel.participantId == id ? .outgoing : .incoming;
            }
            // we were not able to determine if we were senders or not.
            return direction;
        case .occupant(let nickname, let jid):
            if let senderJid = jid {
                return senderJid == conversation.account ? .outgoing : .incoming;
            }
            if let room = conversation as? Room {
                return room.nickname == nickname ? .outgoing : .incoming;
            }
            // we were not able to determine if we were senders or not.
            return direction;
        }
    }

    static func calculateState(direction: MessageDirection, message: Message, isFromArchive archived: Bool, isMuc: Bool) -> ConversationEntryState {
        let error = message.type == StanzaType.error;
        let unread = (!archived) || isMuc;
        if direction == .incoming {
            if error {
                return .incoming_error(unread ? .received : .displayed, errorMessage: message.errorText ?? message.errorCondition?.rawValue);
            }
            return .incoming(unread ? .received : .displayed);
        } else {
            if error {
                return .outgoing_error(unread ? .received : .displayed,errorMessage: message.errorText ?? message.errorCondition?.rawValue);
            }
            return .outgoing(.sent);
        }
    }
    
    private static var syncSinceQueue = DispatchQueue(label: "syncSinceQueue");
    private static var syncSince: [BareJID: Date] = [:];
        
    static func scheduleMessageSync(for account: BareJID) {
        if let syncMessagesSince = DBChatHistoryStore.instance.lastMessageTimestamp(for: account) {
            // use last "received" stable stanza id for account MAM archive in case of MAM:2?
            syncSinceQueue.async {
                self.syncSince[account] = syncMessagesSince;
            }
        }
    }
        
    static func syncMessagesScheduled(for client: XMPPClient) {
        syncSinceQueue.async {
            let syncMessagesSince = syncSince.removeValue(forKey: client.userBareJid);
            syncMessages(for: client, since: syncMessagesSince);
        }
    }
        
    static func syncMessages(for client: XMPPClient, version: MessageArchiveManagementModule.Version? = nil, componentJID: JID? = nil, since: Date? = nil, rsmQuery: RSM.Query? = nil) {
        if let since = since {
            let period = DBChatHistorySyncStore.Period(account: client.userBareJid, component: componentJID?.bareJid, from: since, after: nil, to: nil);
            DBChatHistorySyncStore.instance.addSyncPeriod(period);
        }
        
        syncMessagePeriods(for: client, version: version, componentJID: componentJID?.bareJid)
    }
        
    static func syncMessagePeriods(for client: XMPPClient, version: MessageArchiveManagementModule.Version? = nil, componentJID jid: BareJID? = nil) {
        guard let first = DBChatHistorySyncStore.instance.loadSyncPeriods(forAccount: client.userBareJid, component: jid).first else {
            if jid != nil {
                DBChatMarkersStore.instance.syncCompleted(forAccount: client.userBareJid, with: jid!);
            }
            eventsPublisher.send(.finished(account: client.userBareJid, with: jid));
            return;
        }

        eventsPublisher.send(.started(account: client.userBareJid, with: jid));
            
        syncSinceQueue.async {
            syncMessages(for: client, period: first, version: version);
        }
    }
    
    static func syncMessages(for client: XMPPClient, period: DBChatHistorySyncStore.Period, version: MessageArchiveManagementModule.Version? = nil, rsmQuery: RSM.Query? = nil, retry: Int = 3) {
        let start = Date();
        let queryId = UUID().uuidString;
        let account = client.userBareJid;
        client.module(.mam).queryItems(version: version, componentJid: period.component == nil ? nil : JID(period.component!), start: period.from, end: period.to, queryId: queryId, rsm: rsmQuery ?? RSM.Query(after: period.after, max: 150), completionHandler: { [weak client] result in
            switch result {
            case .success(let response):
                if response.complete || response.rsm == nil {
                    DBChatHistorySyncStore.instance.removeSyncPerod(period);
                    if let client = client {
                        syncMessagePeriods(for: client, version: version, componentJID: period.component);
                    }
                } else {
                    if let last = response.rsm?.last, UUID(uuidString: last) != nil {
                        DBChatHistorySyncStore.instance.updatePeriod(period, after: last);
                    }
                    DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
                        guard let client = client else {
                            return;
                        }
                        self.syncMessages(for: client, period: period, version: version, rsmQuery: response.rsm?.next(150));
                    }
                }
                os_log("for account %s fetch for component %s with id %s executed in %f s", log: .chatHistorySync, type: .debug, period.account.stringValue, period.component?.stringValue ?? "nil", queryId, Date().timeIntervalSince(start));
            case .failure(let error):
                guard client?.state ?? .disconnected() == .connected(), retry > 0 && error != .feature_not_implemented else {
                    os_log("for account %s fetch for component %s with id %s could not synchronize message archive for: %{public}s", log: .chatHistorySync, type: .debug, period.account.stringValue, period.component?.stringValue ?? "nil", queryId, error.description);
                    if period.component != nil {
                        DBChatMarkersStore.instance.syncCompleted(forAccount: account, with: period.component!);
                    }
                    eventsPublisher.send(.finished(account: period.account, with: period.component))
                    return;
                }
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1) {
                    guard let client = client else {
                        return;
                    }
                    self.syncMessages(for: client, period: period, version: version, rsmQuery: rsmQuery, retry: retry - 1);
                }
            }
        });
    }

    static func extractRealAuthor(from message: Message, for conversation: ConversationKey) -> (ConversationEntrySender,ConversationEntryRecipient)? {
        if message.type == .groupchat {
            if let mix = message.mix {
                if let id = message.from?.resource, let nickname = mix.nickname {
                    return (.participant(id: id, nickname: nickname, jid: mix.jid), .none);
                }
                // invalid sender? what should we do?
                return nil;
            } else {
                // in this case it is most likely MUC groupchat message..
                if let nickname = message.from?.resource {
                    return (.occupant(nickname: nickname, jid: nil), .none);
                }
                // invalid sender? what should we do?
                return nil;
            }
        } else {
            // this can be 1-1 message from MUC..
            if let room = conversation as? Room, message.findChild(name: "x", xmlns: "http://jabber.org/protocol/muc#user") != nil {
                if conversation.account == message.from?.bareJid {
                    // outgoing message!
                    if let recipientNickname = message.to?.resource {
                        return (.occupant(nickname: room.nickname, jid: nil), .occupant(nickname: recipientNickname));
                    }
                } else {
                    // incoming message!
                    if let senderNickname = message.from?.resource {
                        return (.occupant(nickname: senderNickname, jid: nil), .occupant(nickname: room.nickname));
                    }
                }
                // invalid sender? what should we do?
                return nil;
            }
        }
        return (conversation.account == message.from?.bareJid ? .me(conversation: conversation) : .buddy(conversation: conversation), .none);
    }
    
    static func itemType(fromMessage message: Message) -> ItemType {
        if let oob = message.oob {
            if (message.body == nil || oob == message.body), URL(string: oob) != nil {
                return .attachment;
            }
        }
        return .message;
    }
}
