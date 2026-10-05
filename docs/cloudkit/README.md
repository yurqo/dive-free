# CloudKit schema correction for 1.4.2

Import `cloudkit-development-1.4.2.ckdb` into the **Development** environment of
`iCloud.org.yurko.divefree`, then review and deploy its additions with **Deploy
Schema Changes**. Verify sync using the existing App Store/TestFlight app.
Importing into Development alone does not repair the production environment.

The baseline is the user's CloudKit Console export supplied on 2026-10-05.
`cloudkit-development-before.ckdb` preserves it exactly. The generated SwiftData
model was inspected using `NSManagedObjectModel.makeManagedObjectModel(for:)`
with all eight `DiveSchema.models`. These persistence definitions match release
`v1.4.2` (`9f62052`) and are unchanged at the current repository HEAD.

The correction preserves every existing record type, field, index and grant. It
adds `CD_NoteMutationRecord`, the missing note fields, previously absent optional
fields and photo relationships, and the `*_ckAsset` fields Core Data uses for
variable-length String/Binary Data attributes. UUIDs and relationship foreign keys
retain their String mapping without asset companions. There are no many-to-many
relationships or inherited entities in this model.

See `schema-1.4.2.diff` for the additions, `model-1.4.2.json` for the inspected
model, and `schema-1.4.2-report.json` for hashes and local checks. Local checks
confirmed complete model field coverage, matching data types, no duplicate fields,
preserved existing definitions and an unchanged Users record. The agent prepared
the schema without Console access or a management token. On 2026-10-05, the user
reported completing the schema correction and confirmed that iCloud sync now
works. Production deployment was performed by the user, not by these preparation
scripts. No app-code change was required for this repair.

References:

- [Core Data record mappings](https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data)
- [Schema import format](https://developer.apple.com/videos/play/wwdc2021/10118/)
- [Production deployment](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)

The attempted simulator initializer was removed in favor of this import. The
original simulator app was restored and the simulator shut down. No cloud data
or production schema was changed by these preparation steps.
