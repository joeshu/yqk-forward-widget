"""Official CCTV daily EPG, independently cached from video preparation."""
from datetime import datetime, timedelta, timezone
import xml.etree.ElementTree as ET

EPG_CHINA = timezone(timedelta(hours=8))


def epg_day(now=None):
    return datetime.fromtimestamp(time.time() if now is None else now, EPG_CHINA).date()


def parse_epg(raw, channels, day):
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError('epg-invalid-response')
    beginning = datetime.combine(day, datetime.min.time(), EPG_CHINA).timestamp()
    result = {}
    for cid in channels:
        source = payload.get(cid)
        if not isinstance(source, dict) or not isinstance(source.get('program'), list):
            continue
        if len(source['program']) > 500:
            continue
        rows = set()
        for item in source['program']:
            if not isinstance(item, dict):
                continue
            title, start, stop = item.get('t'), item.get('st'), item.get('et')
            if (not isinstance(title, str) or not title.strip() or len(title) > 512
                    or any(not (c in '\t\n\r' or 0x20 <= ord(c) <= 0xD7FF
                                or 0xE000 <= ord(c) <= 0xFFFD or 0x10000 <= ord(c) <= 0x10FFFF) for c in title)
                    or type(start) not in (int, float) or type(stop) not in (int, float)):
                continue
            if beginning <= start < beginning+86400 and 0 < stop-start <= 86400:
                rows.add((int(start), int(stop), title.strip()))
        # Empty upstream data is not evidence that yesterday's data is current.
        if rows or not source['program']:
            result[cid] = tuple(sorted(rows))
    return result


def render_epg(channels, schedules):
    root = ET.Element('tv', {'generator-info-name':'cctv-aptv-official'})
    for cid, name in channels.items():
        channel = ET.SubElement(root, 'channel', {'id':cid})
        ET.SubElement(channel, 'display-name', {'lang':'zh'}).text = name
        unique = set()
        for (row_day, row_cid), rows in schedules.items():
            if row_cid == cid:
                unique.update(rows)
        for start, stop, title in sorted(unique):
            fmt = lambda value: datetime.fromtimestamp(value, EPG_CHINA).strftime('%Y%m%d%H%M%S %z')
            programme = ET.SubElement(root, 'programme', {'channel':cid,'start':fmt(start),'stop':fmt(stop)})
            ET.SubElement(programme, 'title', {'lang':'zh'}).text = title
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


class OfficialEPG:
    def __init__(self, channels):
        self.channels = channels
        self.lock = threading.RLock()
        self.ready = threading.Event()
        self.rows, self.body = {}, None
        self.worker = None
        self.closed = False
        self.updated_day = None
        self.next_refresh = 0
        self.error = ''
        self.missing = list(channels)
        self.programmes = 0

    def refresh(self):
        with self.lock:
            if self.closed or self.worker and self.worker.is_alive() or (self.updated_day == epg_day() and time.monotonic() < self.next_refresh):
                return
            self.ready.clear()
            self.worker = threading.Thread(target=self._refresh, name='cctv-epg', daemon=True)
            self.worker.start()

    def _refresh(self):
        today = epg_day()
        updates, failures = {}, False
        # Batched channel requests: three requests, no 14-thread CPU/network burst.
        for offset in (0, 1, -1):
            day = today+timedelta(days=offset)
            with self.lock:
                if self.closed:
                    return
            try:
                query = urlencode({'serviceId':'cbox','c':','.join(self.channels),'d':day.strftime('%Y%m%d')})
                raw, _ = get('https://api.cntv.cn/epg/epginfo?'+query, limit=2*1024*1024, timeout=6)
                parsed = parse_epg(raw, self.channels, day)
                failures |= len(parsed) != len(self.channels)
                updates.update({(day,cid):rows for cid, rows in parsed.items()})
            except Exception:
                failures = True
            with self.lock:
                if self.closed:
                    return
                self._publish(today, updates)
        with self.lock:
            if self.closed:
                return
            self.updated_day = today
            self.error = 'epg-upstream-partial' if failures or self.missing else ''
            self.next_refresh = time.monotonic()+(30 if self.error else 900)
            self.ready.set()

    def _publish(self, today, updates):
        # Publish today's result before fetching tomorrow/yesterday. Never wait
        # for all three days just to show the current programme.
        self.rows = {key:rows for key, rows in self.rows.items()
                     if today-timedelta(days=1) <= key[0] <= today+timedelta(days=1)}
        self.rows.update(updates)
        self.missing = [cid for cid in self.channels if not self.rows.get((today,cid))]
        self.programmes = sum(len(rows) for rows in self.rows.values())
        self.body = render_epg(self.channels, self.rows) if self.programmes else None
        if self.body:
            self.ready.set()

    def document(self):
        self.refresh()
        with self.lock:
            body = self.body
        if body is None:
            self.ready.wait(8)
        with self.lock:
            return self.body

    def snapshot(self):
        with self.lock:
            return {'programmes':self.programmes,'missing_channels':list(self.missing),
                    'refreshing':bool(self.worker and self.worker.is_alive()),'error':self.error,
                    'day':str(self.updated_day) if self.updated_day else None}

    def close(self):
        with self.lock:
            self.closed = True
            self.ready.set()
