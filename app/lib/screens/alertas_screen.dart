import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/app_models.dart';
import '../state/app_state.dart';
import '../widgets/top_bar.dart';

class AlertasScreen extends StatefulWidget {
  const AlertasScreen({super.key});

  @override
  State<AlertasScreen> createState() => _AlertasScreenState();
}

class _AlertasScreenState extends State<AlertasScreen> {
  String filter = 'todos';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final items = state.alerts.where((e) => filter == 'todos' || e.category == filter).toList();

    return Column(
      children: [
        ScreenTopBar(title: 'Alertas y eventos', onBack: () => state.showScreen(ScreenNames.sistema)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppColors.surface1,
              border: Border.all(color: AppColors.lineSoft),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _FilterTab('todos', 'Todos', filter, (f) => setState(() => filter = f)),
                _FilterTab('sistema', 'Sistema', filter, (f) => setState(() => filter = f)),
                _FilterTab('sensores', 'Sensores', filter, (f) => setState(() => filter = f)),
                _FilterTab('red', 'Red', filter, (f) => setState(() => filter = f)),
              ],
            ),
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Sin eventos en esta categoría.', style: TextStyle(color: AppColors.text3, fontSize: 12)))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.lineSoft),
                  itemBuilder: (context, i) => _EventRow(event: items[i]),
                ),
        ),
      ],
    );
  }
}

class _FilterTab extends StatelessWidget {
  final String value;
  final String label;
  final String current;
  final ValueChanged<String> onTap;
  const _FilterTab(this.value, this.label, this.current, this.onTap);

  @override
  Widget build(BuildContext context) {
    final active = value == current;
    return Expanded(
      child: GestureDetector(
        onTap: () => onTap(value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
          decoration: BoxDecoration(color: active ? AppColors.surface3 : Colors.transparent, borderRadius: BorderRadius.circular(9)),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: active ? AppColors.text1 : AppColors.text2)),
        ),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final AlertEvent event;
  const _EventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Container(width: 8, height: 8, decoration: BoxDecoration(color: event.level, shape: BoxShape.circle)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.timeLabel, style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, color: AppColors.text3)),
                const SizedBox(height: 2),
                Text(event.text, style: const TextStyle(fontSize: 12.5, color: AppColors.text1, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
