// Runs once, the first time the MongoDB volume is created.
// Creates the database and collection that the "Archive Raw Payload" node writes to.
db = db.getSiblingDB('leadqualifyflow');
db.createCollection('raw_payloads');
