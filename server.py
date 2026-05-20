import socket
import struct
import threading
import sys

XOR_KEY = b'default_key_32bytes_long!'[:32]  # ровно 32 байта

def xor_crypt(data: bytes) -> bytes:
    return bytes(b ^ XOR_KEY[i % len(XOR_KEY)] for i, b in enumerate(data))

def recv_msg(sock):
    """Принять длину (2 байта) + зашифрованное сообщение."""
    raw = sock.recv(2)
    if not raw:
        return None
    length = int.from_bytes(raw, 'big')
    data = b''
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            return None
        data += chunk
    return xor_crypt(data)  # расшифровали

def send_msg(sock, data: bytes):
    """Отправить длину + зашифрованное сообщение."""
    encrypted = xor_crypt(data)
    header = len(encrypted).to_bytes(2, 'big')
    sock.sendall(header + encrypted)

def handle_client(client_sock, addr):
    print(f"Новое подключение от {addr}")
    try:
        # Первое сообщение – команда соединения
        connect_cmd = recv_msg(client_sock)
        if not connect_cmd or connect_cmd[0] != 0x01:
            print("Неверная команда")
            client_sock.close()
            return

        addr_len = connect_cmd[1]
        dst_addr = connect_cmd[2:2+addr_len].decode()
        dst_port = int.from_bytes(connect_cmd[2+addr_len:2+addr_len+2], 'big')
        print(f"Клиент хочет соединиться с {dst_addr}:{dst_port}")

        # Подключаемся к цели
        remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        remote.connect((dst_addr, dst_port))

        # Двунаправленная пересылка
        def forward(src, dest, direction):
            try:
                while True:
                    if direction == 'client_to_remote':
                        msg = recv_msg(src)
                    else:
                        msg = src.recv(4096)
                    if not msg:
                        break
                    if direction == 'client_to_remote':
                        remote.sendall(msg)          # от клиента пришло расшифрованное – шлём в цель
                    else:
                        send_msg(dest, msg)          # от цели – шифруем и шлём клиенту
            except:
                pass
            finally:
                src.close()
                dest.close()

        t1 = threading.Thread(target=forward, args=(client_sock, remote, 'client_to_remote'))
        t2 = threading.Thread(target=forward, args=(remote, client_sock, 'remote_to_client'))
        t1.start()
        t2.start()
        t1.join()
        t2.join()

    except Exception as e:
        print(f"Ошибка: {e}")
    finally:
        client_sock.close()

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5555
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(('0.0.0.0', port))
    server.listen(10)
    print(f"Сервер запущен на порту {port}")
    try:
        while True:
            client, addr = server.accept()
            threading.Thread(target=handle_client, args=(client, addr), daemon=True).start()
    except KeyboardInterrupt:
        print("Остановка сервера")
    finally:
        server.close()

if __name__ == '__main__':
    main()
