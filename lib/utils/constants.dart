class SyncStatus {
  static const synced = 'synced';
  static const pending = 'pending';
  static const failed = 'failed';
  static const conflict = 'conflict';
}

class OutboxStatus {
  static const queued = 'queued';
  static const inFlight = 'in_flight';
  static const done = 'done';
  static const failed = 'failed';
}

class OutboxOp {
  static const insert = 'insert';
  static const update = 'update';
  static const delete = 'delete';
  static const upload = 'upload';
  static const setPath = 'set_path'; // set storage_path after the upload
}

class EntityType {
  static const note = 'note';
  static const attachment = 'attachment';
}

class Lane {
  static const data = 'data'; // note text and metadata rows
  static const file = 'file'; // file uploads, so big files don't block text
}