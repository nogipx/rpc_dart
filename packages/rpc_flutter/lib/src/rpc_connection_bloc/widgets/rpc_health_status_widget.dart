import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:rpc_flutter/rpc_flutter.dart';

class RpcHealthStatusWidget extends StatelessWidget {
  const RpcHealthStatusWidget({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final healthBloc = context.read<RpcConnectionBloc>();
    return BlocBuilder<RpcConnectionBloc, RpcConnectionState>(
      builder: (context, state) {
        // Определяем отображение по статусу
        Color color;
        IconData icon;
        String label;

        switch (state.status) {
          case RpcConnectionHealthStatus.healthy:
            color = Colors.green;
            icon = Icons.check_circle;
            label = 'Подключено';
            break;
          case RpcConnectionHealthStatus.connecting:
            color = Colors.orange;
            icon = Icons.autorenew;
            label = 'Подключение...';
            break;
          case RpcConnectionHealthStatus.unhealthy:
            color = Colors.red;
            icon = Icons.error;
            label = 'Ошибка связи';
            break;
          case RpcConnectionHealthStatus.disconnected:
          default:
            color = Colors.grey;
            icon = Icons.cloud_off;
            label = 'Отключено';
            break;
        }

        final checking = state.checking;
        final reconnecting = state.reconnecting;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, color: color, size: 28),
                if (checking || reconnecting)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black.withValues(alpha: 0.6),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Row(
                  children: [
                    if (checking)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          'Проверка...',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[700],
                          ),
                        ),
                      ),
                    if (reconnecting)
                      Text(
                        'Переподключение...',
                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(width: 12),
            // Кнопки: подключить / отключить
            if (state.status != RpcConnectionHealthStatus.healthy)
              ElevatedButton(
                onPressed: () {
                  final data = context.read<RpcConnectionInitialData>();
                  healthBloc.add(RpcConnectionStart(data: data));
                },
                child: const Text('Подключить'),
              )
            else
              OutlinedButton(
                onPressed: () {
                  healthBloc.add(const RpcConnectionStop());
                },
                child: const Text('Отключить'),
              ),
          ],
        );
      },
    );
  }
}
