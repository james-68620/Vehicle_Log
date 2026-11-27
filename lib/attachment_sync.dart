import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:smb_connect/smb_connect.dart';

import 'attachments.dart';
import 'database.dart';
import 'models.dart';
import 'settings.dart';
import 'sync_service.dart';

// Moves receipt files between this device and the server.
//
// On the server, inside the sync folder, there is an "attachments" folder:
//   <id>.jpg         the smaller copy of a photo
//   <id>.orig.jpg    the full-size original of a photo (any original type)
//   <id>.pdf         a PDF
class AttachmentSync {
  AttachmentSync._();

  // Runs at the end of every data sync, on the connection it already has.
  static Future<void> run(SmbConnect connect, String remoteFolder) async {
    final folder = await _ensureFolder(connect, remoteFolder);

    final onServer = <String>{};
    for (final file in await connect.listFiles(folder)) {
      onServer.add(file.path.split('/').last);
    }

    final dir = await AttachmentStore.directoryPath();
    final fullSync = settings.attachmentsFullSync;

    for (final a in await AppDatabase.loadAllAttachments()) {
      final smallName = AttachmentStore.displayName(a);
      final originalName = AttachmentStore.originalName(a);
      final localSmall = File(p.join(dir, smallName));
      final localOriginal = File(p.join(dir, originalName));

      try {
        // Deleted somewhere: remove the files from the server and from here.
        if (a.deleted) {
          for (final name in [smallName, originalName]) {
            if (onServer.remove(name)) {
              await _deleteRemote(connect, '$remoteFolder/$name');
            }
          }
          for (final file in [localSmall, localOriginal]) {
            if (await file.exists()) await file.delete();
          }
          continue;
        }

        // Upload what this device has and the server doesn't.
        if (!onServer.contains(smallName) && await localSmall.exists()) {
          await _upload(connect, '$remoteFolder/$smallName', localSmall);
          onServer.add(smallName);
        }
        if (a.kind == 'image' &&
            !onServer.contains(originalName) &&
            await localOriginal.exists()) {
          await _upload(connect, '$remoteFolder/$originalName', localOriginal);
          onServer.add(originalName);
          // The server keeps the original now, so free the space here.
          await localOriginal.delete();
        }

        // Full sync mode: fetch anything this device is missing.
        if (fullSync &&
            onServer.contains(smallName) &&
            !await localSmall.exists()) {
          await _download(connect, '$remoteFolder/$smallName', localSmall);
        }
      } catch (e) {
        debugPrint('Receipt ${a.id}: $e'); // carry on with the others
      }
    }
  }

  // ---- fetching a single file when you open it ----

  // Makes sure the copy shown on this device exists, downloading if needed.
  static Future<void> ensureLocal(Attachment a) async {
    final file = await AttachmentStore.displayFile(a);
    if (await file.exists()) return;
    await _fetch(AttachmentStore.displayName(a), file);
  }

  // Downloads the full-size original of a photo from the server.
  static Future<void> fetchOriginal(Attachment a) async {
    final file = await AttachmentStore.originalFile(a);
    if (await file.exists()) return;
    await _fetch(AttachmentStore.originalName(a), file);
  }

  static Future<void> _fetch(String name, File target) async {
    SmbConnect? connect;
    try {
      connect = await syncService.connectForReceipts();
      final folder = await syncService.receiptsFolderPath();
      await _download(connect, '$folder/$name', target);
    } on TimeoutException {
      throw 'Could not reach the server (not on your home network?)';
    } finally {
      await connect?.close();
    }
  }

  // ---- low-level helpers ----

  static Future<SmbFile> _ensureFolder(SmbConnect connect, String path) async {
    final folder = await connect.file(path);
    if (folder.isExists) return folder;
    return connect.createFolder(path);
  }

  static Future<void> _deleteRemote(SmbConnect connect, String path) async {
    final file = await connect.file(path);
    if (file.isExists) await connect.delete(file);
  }

  // Uploads under a temporary name, then renames, so a half-sent file can
  // never be mistaken for a finished one.
  static Future<void> _upload(
    SmbConnect connect,
    String path,
    File local,
  ) async {
    final temp = '$path.part';
    var file = await connect.file(temp);
    if (file.isExists) await connect.delete(file); // left over from a failure
    file = await connect.createFile(temp);

    final writer = await connect.openWrite(file);
    var sinceFlush = 0;
    await for (final chunk in local.openRead()) {
      writer.add(chunk);
      sinceFlush += chunk.length;
      if (sinceFlush > 2 * 1024 * 1024) {
        await writer.flush();
        sinceFlush = 0;
      }
    }
    await writer.flush();
    await writer.close();

    await connect.rename(file, path);
  }

  // Downloads to a temporary file, then renames it into place.
  static Future<void> _download(
    SmbConnect connect,
    String remotePath,
    File target,
  ) async {
    final remote = await connect.file(remotePath);
    if (!remote.isExists) {
      throw 'This file is not on the server (yet). It may not have been '
          'uploaded from the other device.';
    }

    final part = File('${target.path}.part');
    final sink = part.openWrite();
    try {
      final stream = await connect.openRead(remote);
      await for (final chunk in stream) {
        sink.add(chunk);
      }
      await sink.flush();
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (await part.exists()) await part.delete();
      rethrow;
    }
    await sink.close();
    await part.rename(target.path);
  }
}
