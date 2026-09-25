import 'package:flutter_test/flutter_test.dart';
import 'package:rental_app/main.dart';

void main() {
  testWidgets('RentalApp loads', (WidgetTester tester) async {
    await tester.pumpWidget(const RentalApp());

    expect(find.text('RentalApp'), findsOneWidget);
    expect(find.text('Find your next home'), findsOneWidget);
  });
}