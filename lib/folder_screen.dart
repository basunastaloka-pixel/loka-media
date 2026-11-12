import 'package:flutter/material.dart';
import 'dart:io'; // Tambahkan ini jika nantinya menggunakan File gambar lokal HP

// 1. Model PhotoItem (Definisi tipe data agar tidak merah)
class PhotoItem {
  final String id;
  final String imageUrl; // Berisi URL gambar atau path file lokal

  PhotoItem({
    required this.id,
    required this.imageUrl,
  });
}

class FolderScreen extends StatelessWidget {
  final Map<String, List<PhotoItem>> folderContents;

  const FolderScreen({super.key, required this.folderContents});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hasil Pemilahan Folder'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: folderContents.entries.map((entry) {
          String folderName = entry.key;
          List<PhotoItem> photos = entry.value;

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ExpansionTile(
              leading: const Icon(Icons.folder, color: Colors.amber),
              title: Text(
                folderName,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text('${photos.length} foto/video'),
              children: [
                if (photos.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text('Belum ada foto di folder ini',
                        style: TextStyle(color: Colors.grey)),
                  )
                else
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 4,
                      mainAxisSpacing: 4,
                    ),
                    itemCount: photos.length,
                    itemBuilder: (context, index) {
                      final item = photos[index];
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: item.imageUrl.startsWith('http')
                                ? Image.network(
                                    item.imageUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (ctx, err, stack) =>
                                        const Icon(Icons.broken_image,
                                            color: Colors.grey),
                                  )
                                : Image.file(
                                    File(item.imageUrl),
                                    fit: BoxFit.cover,
                                    errorBuilder: (ctx, err, stack) =>
                                        const Icon(Icons.broken_image,
                                            color: Colors.grey),
                                  ),
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Icon(
                                Icons.cloud_done,
                                size: 14,
                                color: Colors.lightBlueAccent,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}