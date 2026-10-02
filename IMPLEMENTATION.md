# DialyCare shared backend and setup

## What is implemented

The existing Windows staff application and Android/iOS application now share `core_shared`. Production starts at Firebase email/password sign-in. A server-provisioned `dcUsers/{uid}` document determines the active role and center. The role chooser never grants authorization. The clearly labelled demo is in memory only and sends no messages.

The supplied JPG is preserved at `core_shared/assets/dialycare_logo.jpg`, registered as a Flutter package asset, and displayed with `BoxFit.contain`.

### Current deployment status

No production data or deployed rules were changed. No Firebase admin credentials or authenticated Firebase CLI session were available. Therefore deployed collection names and existing rules could not be inspected. The repository had no Firestore services or SMS API implementation. The server implementation below is a **new isolated `dcCenters` / `dcUsers` schema proposal**, not a migration of unknown existing collections. Inspect the live schema and merge rules before production deployment.

The existing SMS provider, endpoint contract, and secrets have not been supplied. The adapter fails closed and logs a blocked outcome until configured. No real push or SMS delivery has been claimed or tested.

## Record model and access

- `dcUsers/{uid}`: `{active: true, role: "admin" | "staff" | "patient" | "relative", centerId: "..."}`. Only an Admin SDK provisioning process can grant access.
- `dcUsers/{uid}/private/preferences`: one current device token, push enablement, preferred channel. Users can change preferences through authenticated commands. Tokens are never bundled in the application. This first version supports one registered push device per account.
- `dcCenters/{centerId}`: center name, `escalationMinutes` (default 15), `reminderMinutes` (default 60), `smsAlways` (default false).
- `patients`: personal, separate designated-relative and emergency-contact fields, optional verified account UIDs, and medical fields. Only staff/admin may read these full records. Patients/relatives read permitted schedule summaries only.
- `sessions`: patient ID/name, start/end UTC milliseconds, Manila day, room, Batch A/B/C, explicit status, version, authorized viewer UIDs, pickup generation/recipient/response/timestamps.
- `notifications`: immutable rendered messages, exact recipient snapshot, related record IDs, creation time, per-user read flags, and channel attempt logs. A queued notification is not a delivered message.
- `audit`: server actor, action, timestamp, reason, before/after. Client writes are forbidden.
- `operations`, `reminders`: server-only idempotency markers.
- `templates`: admin-editable templates for all nine requested message types. Placeholders: `{name}`, `{date}`, `{center}`. Lock-screen push text stays generic; the rendered private message is transported in FCM data and is available in the authenticated app. SMS templates should not include diagnosis, treatment details, or other unnecessary health information.

Firestore rules are not filters: mobile queries explicitly constrain `viewerUids` or `recipientUid`. Direct client writes are denied; mutations use `careCommand`. Contact UID links are verified for active accounts, matching center and role. Contact edits update session visibility. Pickup responses also verify the current patient contact link and request generation, preventing responses to superseded requests.

## Workflow and counts

Status transitions:

`Scheduled -> Waiting -> In Progress -> Completed -> Ready for Pickup -> Picked Up`

Scheduled/Waiting may also become Missed or Cancelled. Cancellation, missed attendance and handover require a reason. Schedule edits/reassignment are limited to Scheduled/Waiting and require a change reason. An overlapping appointment for the same patient OR room is rejected server-side inside a Firestore transaction; adjacent intervals are valid. Concurrent edits require the correct version.

Completed and Ready for Pickup are separate. Only Ready for Pickup creates the designated-relative pickup request. A relative can respond only to their current assigned request. A refusal or timeout enables staff escalation to the separately recorded emergency contact. Escalation is **staff-confirmed**, not an automatic SMS interpretation. The server reminder job flags the timeout. Staff records actual handover as Picked Up.

Counts use Asia/Manila (UTC+08, no daylight saving):

- Total Patients Today: distinct patient IDs in today's non-cancelled sessions (Missed still counts as an expected patient).
- Active Sessions: In Progress.
- Pending: Scheduled + Waiting.
- Completed: Completed + Ready for Pickup + Picked Up.

The greeting refreshes every 30 seconds: morning 05:00–11:59, afternoon 12:00–17:59 (including 15:00), evening otherwise. Session progress is elapsed planned time, never an automatic clinical status change. Reports are derived from saved sessions; they no longer invent completed historical rows.

## Local commands

From `dialycare_staff`:

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

From `dialycare_patient`:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter run -d <android-device-id>
```

Sign in with a provisioned account, or explicitly select **Explore explicit demo**. Demo updates are not synchronized between app instances and reset when the app closes. A failed live connection never silently switches to demo.

## Firebase deployment prerequisites

1. Obtain authorized Firebase project access. Use the existing project `dialycare-backend-3f0ed`; preserve both generated `firebase_options.dart` files.
2. Before deploying, inspect live collections and existing rules. `functions/inspect-schema.cjs` lists collection names only using Application Default Credentials. Confirm whether the proposed isolated schema should be used or mapped to existing data. Do not replace unrelated production rules.
3. Enable Email/Password authentication and create test staff, patient and relative accounts. Set server-provisioned role documents using the Firebase Admin SDK; no public sign-up can choose staff/admin. `functions/provision-user.cjs` is an explicit administrator tool; it requires the account to exist.
4. Use Node 22 for Cloud Functions. Install backend dependencies (`npm install` or `pnpm install`) in `backend/functions`. Tests here ran with the bundled Node runtime; the deployment runtime is declared separately.
5. Merge `backend/firestore.rules` into the existing production rules, preserving legacy collections. The supplied rules file is complete for emulator tests and this isolated schema only. It must not be deployed blindly over unknown rules.
6. Deploy `careCommand`, `deliverNotification`, and `reminderSweep` in `asia-southeast1` after reviewing configuration and billing. The Flutter HTTP callable implementation includes Firebase ID tokens. Change both function region and `--dart-define=FUNCTIONS_REGION=...` together if needed.
7. Cloud Scheduler runs `reminderSweep` every five minutes in Asia/Manila: appointment reminders, ending-soon updates, pickup escalation flags and stuck-send reconciliation markers. Enable required billing/APIs and review quotas.
8. Provision the center document and role profiles. In Patients, link the correct Firebase UIDs; saving validates their roles and center. Deactivated users are denied by rules and commands.

## SMS adapter contract (provider configuration still required)

Server environment `SMS_API_URL` must be HTTPS. Secret Manager stores `DIALYCARE_SMS_API_KEY`; the secret is bound only to the delivery function. Set `SMS_ADAPTER_CONFIRMED=true` only after adapting and testing the actual provider contract. The included adapter expects:

- POST JSON `{to, message, clientReference}`
- bearer credential and `Idempotency-Key` header
- success JSON `{messageId: "..."}`

This is an adapter boundary, not a claim about your existing provider API. Provider-specific signing, status codes, idempotency, and delivery receipts must be verified. Credentials must never enter Flutter, assets, `.env` committed to source, or notification logs. Use Secret Manager and ignored environment files.

SMS eligibility requires a registered E.164 number, phone ownership verification and recorded consent. Admins can record/revoke audited contact consent in session details after completing the center's verification procedure. Phone edits revoke prior verification/consent. Patient SMS verification can use the same `verifyContact` command with `contactKind: "patient"` or an audited administrator import.

Fallback applies when SMS is preferred, no eligible push token is available, or `smsAlways` is explicitly configured. An explicit FCM invalid-token rejection can enable eligible SMS; an unacknowledged push never counts as failed delivery. The app states that provider acceptance is not delivery or reading. No delivery-receipt webhook is implemented until the provider's authenticated callback format is supplied.

Outbox IDs are deterministic per event/version/contact. Transactional command request IDs suppress duplicate requests. A worker claims the outbox before sending. Crashes or network timeouts with uncertain provider acceptance are marked unknown; there is intentionally no blind automatic resend. Reconcile with the provider before a deliberate retry. Exactly-once delivery cannot be promised across a provider that does not honor idempotency keys.

## Mobile push and iOS

Android Internet and notification permissions are declared. Users explicitly register the device from Preferences. Android notification permission is requested at runtime. Token refresh updates the server; logout clears the active token. The mobile app has foreground, background and notification-open handling, with Firestore remaining the source of truth.

iOS has remote-notification background mode and `Runner.entitlements`; Debug/Release xcconfig select development/production APNs. On macOS with Xcode, enable Push Notifications on the correct signed App ID, set the signing team, upload the APNs key/certificate to Firebase, verify the registered bundle ID (`com.example.dialycarePatient`), install pods, and build/run. APNs readiness is checked before FCM token registration. This Windows environment cannot build or test iOS.

## Verification and operational boundaries

Recorded verification on 2026-09-25:

- Windows application built and launched successfully with `flutter run -d windows`. Non-fatal Firebase missing-PDB linker warnings remain.
- Staff tests: 8 passed, including navigation, forms, schedule reassignment, notification details and layouts at 1280x720, 1366x768, 1440x900 and 1920x1080.
- Mobile widget tests: 5 passed, including narrow layouts, relative pickup acknowledgment and patient role restrictions.
- Shared domain tests: 5 passed. Backend domain/emulator tests: 7 passed, including Firestore transactions and security rules. These runs preceded the last small shared-domain and delivery-worker refinements; those refinements need a repeat run.
- Eleven desktop screenshots were visually inspected in `dialycare_staff/build/ui-review/connected`. The final Ready for Pickup status-color alias adjustment followed screenshot capture.
- Earlier Flutter analysis identified no remaining compile errors after fixes, but the final formatting/analysis pass was not completed: automatic approval review failed because of an account usage limit. This was a review-system failure, not an unsafe-action finding.
- Android debug build failed because NDK 28.2.13676358 is missing and the installed SDK manager failed while trying to install it. No Android emulator or physical device was available. No successful Android build or device test is claimed.
- iOS configuration is prepared; no macOS/Xcode build or APNs device test was possible here.
- Production Firebase collections/rules were not accessible with administrator credentials, and no production deployment was performed. Real cross-device synchronization, FCM delivery and provider-specific SMS delivery remain unverified until deployment and authorized device/provider testing.

Important modified/created files include `dialycare_staff/lib/main.dart`, `dialycare_staff/lib/screens/staff_portal.dart`, `dialycare_staff/lib/widgets/staff_shell.dart`, `dialycare_staff/lib/widgets/status_chip.dart`, `dialycare_patient/lib/main.dart`, `core_shared/lib/src/{domain,repository,access_gate}.dart`, `core_shared/assets/dialycare_logo.jpg`, the app/shared package manifests and lockfiles, Android/iOS push configuration, the Flutter test suites, and `backend/` (commands, delivery worker, scheduler, templates, security rules, emulator tests and administrator utilities). Existing generated Firebase project options were preserved.

Run Firestore emulator tests from `backend/functions` with Java on PATH:

```powershell
node node_modules/firebase-tools/lib/bin/firebase.js emulators:exec --only firestore --project demo-dialycare --config ../firebase.json "node --test *.test.cjs"
```

These exercise real emulator transactions and security rules, with a demo project and no real sends. The adapter policy tests use test data. Real delivery requires authorized test accounts, devices, push setup, verified consent and SMS provider access.

The first backend version reads center records inside transactions to enforce conflicts, and staff subscriptions read the center's lists. Before large-scale use, introduce paged views and indexed resource/time-slot locks, plus retention/backup policies. Keep per-center data and bulk announcements below Firestore transaction write limits; the server rejects oversized read-all operations rather than reporting success. In uncertain write responses the UI instructs staff to refresh before retrying.

Sources used for integration: https://firebase.google.com/docs/functions/callable-reference ; https://firebase.google.com/docs/firestore/security/rules-query ; https://firebase.google.com/docs/cloud-messaging/flutter/get-started
