import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mechx/store/annotation_store.dart';
import 'package:mechx/store/app_state.dart';
import 'package:mechx/store/network_store.dart';
import 'package:mechx/store/project_store.dart';
import 'package:mechx/ui/canvas/armed_delete.dart';
import 'package:mechx/ui/canvas/room_overlay.dart';
import 'package:mechx/ui/canvas/tank_overlay.dart';
import 'package:mechx_engine/geometry/scale_calibration.dart';
import 'package:mechx_engine/network/network.dart' show NodeComponent;

/// C4 — an armed drafting tool must not destroy work on pointer-DOWN with no
/// confirmation. The delete now completes on pointer-UP after a confirming
/// second secondary-click (the app's "Tap again to discard" idiom rather than a
/// modal), and a status pill names what went — for a room, including the
/// auto-placed air terminals it leaves behind.
///
/// F6 — a just-drawn room/tank is SELECTED, like every drawn node.
void main() {
  group('ArmedSecondaryDelete (pure gesture contract)', () {
    PointerDownEvent down(Offset p, {int buttons = kSecondaryButton}) =>
        PointerDownEvent(position: p, buttons: buttons);
    PointerUpEvent up(Offset p) => PointerUpEvent(position: p);

    test('the first secondary click ARMS; the second DELETES', () {
      final a = ArmedSecondaryDelete();
      a.pointerDown(down(Offset.zero));
      expect(a.pointerUp(up(Offset.zero), 'r0'),
          (action: ArmedDeleteAction.armed, id: 'r0'));
      expect(a.armedId, 'r0');
      a.pointerDown(down(Offset.zero));
      expect(a.pointerUp(up(Offset.zero), 'r0'),
          (action: ArmedDeleteAction.deleted, id: 'r0'));
      expect(a.armedId, isNull);
    });

    test('a PRIMARY click never deletes (the old bug was on down, any button)',
        () {
      final a = ArmedSecondaryDelete();
      a.pointerDown(down(Offset.zero, buttons: kPrimaryButton));
      expect(a.pointerUp(up(Offset.zero), 'r0').action, ArmedDeleteAction.none);
      expect(a.armedId, isNull);
    });

    test('a drag with the secondary button held is not a click', () {
      final a = ArmedSecondaryDelete();
      a.pointerDown(down(Offset.zero));
      expect(a.pointerUp(up(const Offset(40, 0)), 'r0').action,
          ArmedDeleteAction.none);
      expect(a.armedId, isNull);
    });

    test('moving to a DIFFERENT target re-arms rather than deleting', () {
      final a = ArmedSecondaryDelete();
      a.pointerDown(down(Offset.zero));
      a.pointerUp(up(Offset.zero), 'r0');
      a.pointerDown(down(Offset.zero));
      expect(a.pointerUp(up(Offset.zero), 'r1'),
          (action: ArmedDeleteAction.armed, id: 'r1'));
    });

    test('a click on empty canvas cancels a pending confirmation', () {
      final a = ArmedSecondaryDelete();
      a.pointerDown(down(Offset.zero));
      a.pointerUp(up(Offset.zero), 'r0');
      a.pointerDown(down(Offset.zero));
      expect(a.pointerUp(up(Offset.zero), null).action, ArmedDeleteAction.none);
      expect(a.armedId, isNull);
      // …so the next click on r0 arms again instead of deleting.
      a.pointerDown(down(Offset.zero));
      expect(a.pointerUp(up(Offset.zero), 'r0').action, ArmedDeleteAction.armed);
    });

    test('disarm drops a pending confirmation (the tool was switched off)', () {
      final a = ArmedSecondaryDelete();
      a.pointerDown(down(Offset.zero));
      a.pointerUp(up(Offset.zero), 'r0');
      a.disarm();
      a.pointerDown(down(Offset.zero));
      expect(a.pointerUp(up(Offset.zero), 'r0').action, ArmedDeleteAction.armed);
    });
  });

  group('the room overlay honours the contract', () {
    Future<ProviderContainer> pumpRoom(WidgetTester tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
      // The status pill self-clears on a Timer; cancel it so the widget tree is
      // never disposed with one pending.
      addTearDown(() => c.read(statusMessageProvider.notifier).clear());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 500,
              height: 400,
              child:
                  RoomOverlay(sheetId: 's1', floorIndex: 0, active: true),
            ),
          ),
        ),
      );
      return c;
    }

    Future<void> secondaryClick(WidgetTester tester, Offset at) async {
      final g = await tester.startGesture(at, buttons: kSecondaryButton);
      await g.up();
      await tester.pump();
    }

    testWidgets('one right-click only ARMS (the room survives); the second '
        'deletes and the pill names it', (tester) async {
      final c = await pumpRoom(tester);
      c.read(roomAreasProvider.notifier).add(
          sheetId: 's1', floorIndex: 0, ax: 100, ay: 100, bx: 300, by: 260);
      await tester.pump();
      final name = c.read(roomAreasProvider).single.name;

      // Centre of the room in overlay-local coords (identity viewport).
      const centre = Offset(200, 180);
      await secondaryClick(tester, centre);
      expect(c.read(roomAreasProvider), hasLength(1), reason: 'not yet');
      expect(c.read(statusMessageProvider), contains(name));
      expect(c.read(statusMessageProvider), contains('Right-click again'));

      await secondaryClick(tester, centre);
      expect(c.read(roomAreasProvider), isEmpty);
      expect(c.read(statusMessageProvider), contains('$name deleted'));
      c.read(statusMessageProvider.notifier).clear();
      await tester.pump();
    });

    testWidgets('the confirmed pill COUNTS the auto-placed terminals left '
        'behind', (tester) async {
      final c = await pumpRoom(tester);
      c.read(roomAreasProvider.notifier).add(
          sheetId: 's1', floorIndex: 0, ax: 100, ay: 100, bx: 300, by: 260);
      await tester.pump();
      final room = c.read(roomAreasProvider).single;
      // Two diffusers inside the footprint (as auto-place would leave them).
      final net = c.read(networkControllerProvider.notifier);
      net.addComponentNode(
          's1', 0, const Offset(150, 150), NodeComponent.supplyDiffuser);
      net.addComponentNode(
          's1', 0, const Offset(250, 200), NodeComponent.supplyDiffuser);
      await tester.pump();

      const centre = Offset(200, 180);
      await secondaryClick(tester, centre);
      await secondaryClick(tester, centre);
      expect(c.read(roomAreasProvider), isEmpty);
      final pill = c.read(statusMessageProvider)!;
      expect(pill, contains(room.name));
      expect(pill, contains('2 placed terminals'));
      // The terminals themselves are untouched — that is the whole point of
      // saying so.
      expect(c.read(networkControllerProvider).network.nodes, hasLength(2));
      c.read(statusMessageProvider.notifier).clear();
      await tester.pump();
    });

    testWidgets('F6: a just-drawn room is selected', (tester) async {
      final c = await pumpRoom(tester);
      final g = await tester.startGesture(const Offset(80, 80));
      await tester.pump(const Duration(milliseconds: 20));
      await g.moveTo(const Offset(200, 160));
      await tester.pump(const Duration(milliseconds: 20));
      await g.moveTo(const Offset(300, 240));
      await tester.pump(const Duration(milliseconds: 20));
      await g.up();
      await tester.pump();
      final rooms = c.read(roomAreasProvider);
      expect(rooms, hasLength(1));
      final sel = c.read(selectedAnnotationProvider);
      expect(sel?.kind, AnnotationKind.room);
      expect(sel?.id, rooms.single.id);
    });
  });

  group('the tank overlay honours the contract', () {
    testWidgets('two right-clicks delete; F6 selects a just-drawn tank',
        (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c
          .read(projectControllerProvider.notifier)
          .setCalibration('s1', const ScaleCalibration(0.01));
      addTearDown(() => c.read(statusMessageProvider.notifier).clear());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 500,
              height: 400,
              child: TankOverlay(sheetId: 's1', floorIndex: 0, active: true),
            ),
          ),
        ),
      );

      // Draw one by dragging — it must come out selected (F6).
      final draw = await tester.startGesture(const Offset(80, 80));
      await tester.pump(const Duration(milliseconds: 20));
      await draw.moveTo(const Offset(180, 160));
      await tester.pump(const Duration(milliseconds: 20));
      await draw.moveTo(const Offset(280, 240));
      await tester.pump(const Duration(milliseconds: 20));
      await draw.up();
      await tester.pump();
      final tanks = c.read(tankAreasProvider);
      expect(tanks, hasLength(1));
      expect(c.read(selectedAnnotationProvider)?.id, tanks.single.id);

      // The pick is on the tank's CENTRE (a drag's recognized start is past the
      // slop, so read the real bounds rather than assuming the press point).
      final t0 = c.read(tankAreasProvider).single;
      final centre =
          Offset((t0.ax + t0.bx) / 2, (t0.ay + t0.by) / 2);
      var g = await tester.startGesture(centre, buttons: kSecondaryButton);
      await g.up();
      await tester.pump();
      expect(c.read(tankAreasProvider), hasLength(1)); // armed only
      g = await tester.startGesture(centre, buttons: kSecondaryButton);
      await g.up();
      await tester.pump();
      expect(c.read(tankAreasProvider), isEmpty);
      expect(c.read(statusMessageProvider), contains('deleted'));
      c.read(statusMessageProvider.notifier).clear();
      await tester.pump();
    });
  });
}
