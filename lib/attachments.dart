import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'attachment_sync.dart';
import 'database.dart';
import 'models.dart';

const int _maxPixels = 1600; // longest side of the copy kept on this device
const int _maxFileBytes = 40 * 1024 * 1024;
const List<String> _imageTypes = ['.jpg', '.jpeg', '.png', '.webp', '.bmp'];

// Runs in the background so a big photo doesn't freeze the screen.
Uint8List? _shrink(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final upright = img.bakeOrientation(decoded); // honour the phone's rotation
  img.Image result = upright;
  if (upright.width >= upright.height && upright.width > _maxPixels) {
    result = img.copyResize(upright,
        width: _maxPixels, interpolation: img.Interpolation.average);
  } else if (upright.height > upright.width && upright.height > _maxPixels) {
    result = img.copyResize(upright,
        height: _maxPixels, interpolation: img.Interpolation.average);
  }
  return Uint8List.fromList(img.encodeJpg(result, quality: 82));
}

// Saves, finds and removes the receipt files on this device.
class AttachmentStore {
  AttachmentStore._();

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'attachments'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<String> directoryPath() async => (await _dir()).path;

  // File name of the copy shown on this device: the shrunk photo or the PDF.
  // The server uses the same names.
  static String displayName(Attachment a) =>
      '${a.id}.${a.kind == 'pdf' ? 'pdf' : 'jpg'}';

  // File name of the full-size original photo.
  static String originalName(Attachment a) =>
      '${a.id}.orig${p.extension(a.fileName).toLowerCase()}';

  static String pathIn(String dir, Attachment a) => p.join(dir, displayName(a));

  static Future<File> displayFile(Attachment a) async =>
      File(p.join((await _dir()).path, displayName(a)));

  // The untouched original photo, if this device has it.
  static Future<File> originalFile(Attachment a) async =>
      File(p.join((await _dir()).path, originalName(a)));

  // ---- choosing a file ----

  static Future<XFile?> takePhoto() =>
      ImagePicker().pickImage(source: ImageSource.camera);

  static Future<XFile?> chooseFile() => openFile(
        // Android's picker can wrongly grey out files when filtered.
        acceptedTypeGroups: Platform.isAndroid
            ? <XTypeGroup>[]
            : [
                const XTypeGroup(
                  label: 'Photos and PDFs',
                  extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'pdf'],
                ),
              ],
      );

  // ---- adding and removing ----

  static Future<Attachment> add({
    required String parentType,
    required String parentId,
    required XFile file,
  }) async {
    final name = file.name.isNotEmpty ? file.name : p.basename(file.path);
    final ext = p.extension(name).toLowerCase();
    final isPdf = ext == '.pdf';
    if (!isPdf && !_imageTypes.contains(ext)) {
      throw 'Only photos (JPG, PNG) and PDF files can be attached.';
    }

    final bytes = await file.readAsBytes();
    if (bytes.length > _maxFileBytes) {
      throw 'That file is over 40 MB, which is too large to attach.';
    }

    final attachment = Attachment(
      parentType: parentType,
      parentId: parentId,
      fileName: name,
      kind: isPdf ? 'pdf' : 'image',
      originalSize: bytes.length,
    );

    final display = await displayFile(attachment);
    if (isPdf) {
      await display.writeAsBytes(bytes);
    } else {
      final small = await compute(_shrink, bytes);
      if (small == null) throw 'That image could not be read.';
      await display.writeAsBytes(small);
      // Kept here until sync has uploaded it to the server.
      await (await originalFile(attachment)).writeAsBytes(bytes);
    }

    await AppDatabase.saveAttachment(attachment);
    return attachment;
  }

  static Future<void> remove(Attachment a) async {
    await AppDatabase.deleteAttachment(a.id);
    for (final f in [await displayFile(a), await originalFile(a)]) {
      if (await f.exists()) await f.delete();
    }
  }

  static Future<void> removeAllFor(String parentId) async {
    for (final a in await AppDatabase.loadAttachments(parentId)) {
      await remove(a);
    }
  }

  // ---- opening PDFs in the system's viewer ----

  static Future<void> openPdf(Attachment a) async {
    final file = await displayFile(a);
    if (!await file.exists()) throw 'This file is not on this device.';

    if (Platform.isAndroid) {
      // A copy in the cache folder, which Android lets other apps read.
      final tmp = await getTemporaryDirectory();
      final copy = File(p.join(tmp.path, 'receipt-${a.id}.pdf'));
      await file.copy(copy.path);
      final result = await OpenFilex.open(copy.path, type: 'application/pdf');
      if (result.type != ResultType.done) {
        throw 'Could not open the PDF: ${result.message}';
      }
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [file.path]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', file.path]);
    }
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

// ------------------------------------------------------------------ widgets

// The "Receipts and invoices" block shown in the fuel and service forms.
class AttachmentsSection extends StatefulWidget {
  final String parentType; // 'fuel' or 'service'
  final String parentId;

  const AttachmentsSection({
    super.key,
    required this.parentType,
    required this.parentId,
  });

  @override
  State<AttachmentsSection> createState() => _AttachmentsSectionState();
}

class _AttachmentsSectionState extends State<AttachmentsSection> {
  List<Attachment> _items = [];
  String _dir = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dir = await AttachmentStore.directoryPath();
    final items = await AppDatabase.loadAttachments(widget.parentId);
    if (!mounted) return;
    setState(() {
      _dir = dir;
      _items = items;
    });
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _add(Future<XFile?> Function() pick) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await pick();
      if (file != null) {
        await AttachmentStore.add(
          parentType: widget.parentType,
          parentId: widget.parentId,
          file: file,
        );
        await _load();
      }
    } catch (e) {
      if (mounted) _message('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(Attachment a) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Downloads it from the server first if this device doesn't have it.
      await AttachmentSync.ensureLocal(a);
      if (!mounted) return;
      setState(() => _busy = false);

      if (a.kind == 'pdf') {
        await AttachmentStore.openPdf(a);
      } else {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AttachmentViewerPage(attachment: a),
          ),
        );
      }
    } catch (e) {
      if (mounted) _message('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load(); // thumbnails may exist now
  }

  Future<void> _delete(Attachment a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove attachment?'),
        content: Text(a.fileName),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AttachmentStore.remove(a);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Receipts and invoices',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (Platform.isAndroid)
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _add(AttachmentStore.takePhoto),
                icon: const Icon(Icons.photo_camera),
                label: const Text('Take photo'),
              ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _add(AttachmentStore.chooseFile),
              icon: const Icon(Icons.attach_file),
              label: const Text('Choose file'),
            ),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        for (final a in _items) _tile(a),
      ],
    );
  }

  Widget _tile(Attachment a) {
    final path = AttachmentStore.pathIn(_dir, a);
    final onDevice = _dir.isNotEmpty && File(path).existsSync();

    Widget thumbnail;
    if (!onDevice) {
      thumbnail = const Icon(Icons.cloud_download_outlined, size: 32);
    } else if (a.kind == 'pdf') {
      thumbnail = const Icon(Icons.picture_as_pdf, size: 36);
    } else {
      thumbnail = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          cacheWidth: 96,
          errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
        ),
      );
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(width: 48, height: 48, child: thumbnail),
      title: Text(a.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_formatBytes(a.originalSize)}'
        '${onDevice ? '' : '  •  on the server, tap to download'}',
      ),
      onTap: () => _open(a),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Remove',
        onPressed: () => _delete(a),
      ),
    );
  }
}

// Full-screen photo viewer with pinch to zoom.
class AttachmentViewerPage extends StatefulWidget {
  final Attachment attachment;

  const AttachmentViewerPage({super.key, required this.attachment});

  @override
  State<AttachmentViewerPage> createState() => _AttachmentViewerPageState();
}

class _AttachmentViewerPageState extends State<AttachmentViewerPage> {
  String _displayPath = '';
  String _originalPath = '';
  bool _hasOriginal = false;
  bool _showOriginal = false;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final display = await AttachmentStore.displayFile(widget.attachment);
    final original = await AttachmentStore.originalFile(widget.attachment);
    if (!mounted) return;
    setState(() {
      _displayPath = display.path;
      _originalPath = original.path;
      _hasOriginal = original.existsSync();
    });
  }

  // Pulls the full-size original from the server, then shows it.
  Future<void> _downloadOriginal() async {
    setState(() => _downloading = true);
    try {
      await AttachmentSync.fetchOriginal(widget.attachment);
      await _prepare();
      if (mounted) setState(() => _showOriginal = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.attachment.fileName),
        actions: [
          if (_downloading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (_hasOriginal)
            IconButton(
              icon: Icon(_showOriginal ? Icons.hd : Icons.hd_outlined),
              tooltip: _showOriginal ? 'Show smaller copy' : 'Show original',
              onPressed: () => setState(() => _showOriginal = !_showOriginal),
            )
          else
            IconButton(
              icon: const Icon(Icons.cloud_download_outlined),
              tooltip: 'Download original from the server',
              onPressed: _downloadOriginal,
            ),
        ],
      ),
      body: _displayPath.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : InteractiveViewer(
              maxScale: 6,
              child: Center(
                child: Image.file(
                  File(_showOriginal ? _originalPath : _displayPath),
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image, size: 64),
                ),
              ),
            ),
    );
  }
}
