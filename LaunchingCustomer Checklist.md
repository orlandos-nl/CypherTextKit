# LaunchingCustomer Rules

The LaunchingCustomer encrypts-then-saves data in an SQLite database.
Communication happens over XMPP.

## XMPP

- [ ] The XMPP client resets the password after device registration
- [ ] The app publishes its APNS & PushKit Token to XMPP
- [ ] The app publishes changes to UserConfig to XMPP

## Database

- [ ] The database will be wiped after failing to unlock the app 10 times
- [ ] Failed Login Attempts are remembered across boots
- [ ] The last attempt needs to be verified with a 'captcha-like' password
- [ ] Messages are deleted from the database once expired

## UI Rules

- [ ] The UI prevents copy & paste operations within the app
- [ ] Messages are deleted from the UI once expired
- [ ] The app is automatically locked after 15 minutes of activity
- [ ] The app is automatically locked after (1-5) minutes of inactivity

## Chats

- [ ] Images in the chat are blurred out until tap
- [ ] On-Tap, images open an image viewer
- [ ] Unknown message types are rendered as 'unsupported'
- [ ] Leaving the chat or the entire app remembers entered text input in the chatbar
- [ ] Chats are ordered in order of most recent activity
- [ ] Activity is recorded for any text/media/'magic call' message
- [ ] Group chat names are max 30 characters
- [ ] Users can save or forward a subset of messages. This can be a range as selected by the user, but they only set the start and end
- [ ] Users cannot save or forward non-text messages
- [ ] Users must see a status message whenever encryption was reset (for each of their conversations)
- [ ] Users must see a status message whenever a call happened, or was missed
- [ ] Users must see a status message whenever a user's identity changed (for each of their conversations)
- [ ] Users must see a status message whenever someone saved the conversation

## Call

- [ ] Calls happen through WebRTC, and emit a PushKit notification
- [ ] Calls are cancelled after 30 seconds of no reply
- [ ] Necessary (WebRTC) info is communicated through 'magic packets' in the chat
- [ ] A (WebRTC) call client is provided by the Android or iOS client
- [ ] The call can have one active, and 2 total calls. When there are two calls, you can pick which one to continue

## Contacts

- [ ] Users can contact a user, this emits a special push notification
- [ ] Contact Requests are not ignored, unless that user is blocked
- [ ] If you receive a message from a non-contact, the first message is processed as a contact request
    - [ ] Unless that contact was removed, at which point only original contact requests are processed
- [ ] Contact requests carry a text message
- [ ] Contacts share changes to their status
    - [ ] Status changes are shared with everyone when users update their status
    - [ ] Status changes are also shared when both accepted each other as contact
    - [ ] Statuses are max 30 characters
- [ ] Contacts have a username and a nickname, nicknames are client-side only
- [ ] Contacts can be blocked, none of their messages will arive
- [ ] Contacts can be removed, at which point only contact requests or group messages will arive
- [ ] Private Chats can be closed/removed, all messages can arrive
- [ ] Contacts can be favourited, putting on top of the contacts list
- [ ] Contacts can be filtered by a search bar
- [ ] Contacts are alphabetically ordered
- [ ] Users are non-verified by default
- [ ] Verifying is reset to unverified once a user's master device signing key changes
- [ ] Atfer blocking/removing a contact, the blocked/removed user respects not sending notifications
- [ ] Atfer unblocking/(re-)adding a contact, that user sends notifications again

## Vault

- [ ] A Vault can be created by the user
- [ ] Vaults have a separate password
- [ ] The vault is wiped after 10 failed attempts
- [ ] Failed Login Attempts are remembered across boots
- [ ] The last attempt needs to be verified with a 'captcha-like' password
- [ ] Vaults can store notes & images
    - [ ] Notes have titles of max 30 characters
- [ ] Vaults can be used to store backups of conversations
- [ ] Vaults are automatically locked after 1 minute of inactivity

## Settings

- [ ] Profile pictures are shared with other users
- [ ] Status & profile pictures are shared through magic packets
- [ ] You can wipe the app. This also deregisters push tokens

## UI Actions

### Chats

- [ ] Users can share notes & images as 'view-only' or savable
- [ ] Savable items can be saved in your own vault
- [ ] Users can record a voice memo
- [ ] Users can share items from the vault using the attachment icon
- [ ] Users can snap & send photos using a camera button
- [ ] Users can call another user through the private chat
- [ ] Users can forward text messages
- [ ] Titlebar in private chats shows the contact name & icon
- [ ] Tapping the contact in the titlebar opens their profile
- [ ] Chats have a locally defined expiration timer for _all_ messages
- [ ] The expiration timer is attached to each message
- [ ] The other user removes the message after the timer expired
- [ ] The timer updates live
- [ ] You cannot see that others blocked you
- [ ] The chat bar is disabled if you blocked that contact
- [ ] The chat bar is disabled if you didn't accept their contact request
- [ ] The chat bar is disabled if they didn't accept your contact request

### Group Chats

- [ ] _All_ users can change the group name and/or group image
- [ ] Admins can add or kick people
- [ ] Admins can promote others to admin
- [ ] _Everyone_ can leave the group
- [ ] Chat messages by other users show their used icon

### Call

- [ ] Can put the call on speaker
- [ ] Can mute the microphone
- [ ] Calls can be minimized and re-maximized
- [ ] Minimized calls show the time elapsed
- [ ] On proximity (on iOS), the screen goes black, unless it's on speaker
- [ ] Calling has a different ringtone when someone calls you while you're in a call

### Profile

- [ ] Users can verify their combined public keys using emoji's
- [ ] The emoji signature is _identical_ on iOS and Android

### Settings

- [ ] Users can change their app password
- [ ] Users can change their notification & call sounds
- [ ] Users can change their status & profile picture
- [ ] App can be wiped, which removes the APNS & pushkit tokens from the server first

## Backups

- [ ] Users can create a backup of their contacts
- [ ] Backups require a password, entered by the user
- [ ] Backups are stored on a server, and can be restored from the server
- [ ] If a vault exists, the vault is also added to the backup

## Read/Receive Receipts

- [ ] A receive receipt is sent once a message is _processed_
- [ ] Ignored messages are not emitting _any_ receipt
- [ ] Once the user visually sees a message, it's marked as read
- [ ] If the client couldn't send a message, it makes the mesasge as _unsent_ until it can be sent

## Notification Sounds

- [ ] In-app notification sounds are emitted when a message _or_ contact request is received
- [ ] The sound is _not_ played when a user is inside a chat view
- [ ] The sound is _not_ played while locking
