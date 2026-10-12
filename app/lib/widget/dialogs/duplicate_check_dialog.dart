import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';

class DuplicateCheckDialog extends StatelessWidget {
  final String senderAlias;
  final ValueListenable<int> checkedFiles;
  final VoidCallback onCancel;

  const DuplicateCheckDialog({required this.senderAlias, required this.checkedFiles, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(t.receivePage.checkingExistingFiles),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(senderAlias),
            const SizedBox(height: 20),
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            ValueListenableBuilder<int>(
              valueListenable: checkedFiles,
              builder: (context, count, child) => Text(t.receivePage.filesChecked(n: count)),
            ),
          ],
        ),
        actions: [TextButton(onPressed: onCancel, child: Text(t.general.cancel))],
      ),
    );
  }
}
