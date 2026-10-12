import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/dialogs/duplicate_check_dialog.dart';

void main() {
  testWidgets('shows the sender during checking, updates progress and allows cancellation', (tester) async {
    final checkedFiles = ValueNotifier<int>(0);
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: DuplicateCheckDialog(
          senderAlias: 'My phone',
          checkedFiles: checkedFiles,
          onCancel: () => cancelled = true,
        ),
      ),
    );

    expect(find.text(t.receivePage.checkingExistingFiles), findsOneWidget);
    expect(find.text('My phone'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(t.receivePage.filesChecked(n: 0)), findsOneWidget);

    checkedFiles.value = 25;
    await tester.pump();
    expect(find.text(t.receivePage.filesChecked(n: 25)), findsOneWidget);

    await tester.tap(find.text(t.general.cancel));
    expect(cancelled, isTrue);
    await tester.pumpWidget(const SizedBox());
    checkedFiles.dispose();
  });
}
