#!/usr/bin/env python3
import json
import re
import urllib.request
import concurrent.futures
import time

SOURCES = [
    # (url, default_group, default_country)
    ('https://iptv-org.github.io/iptv/countries/mx.m3u', '🇲🇽 México Nacional y Abierta', 'MX'),
    ('https://raw.githubusercontent.com/PABLOPOM/m3u/main/TELEVISION1', '🇲🇽 México Nacional y Abierta', 'MX'),
    ('https://raw.githubusercontent.com/PABLOPOM/m3u/main/TELEVISION', '🇲🇽 México Nacional y Abierta', 'MX'),
    ('https://iptv-org.github.io/iptv/categories/sports.m3u', '⚽ Deportes en Vivo', 'INT'),
    ('https://iptv-org.github.io/iptv/categories/movies.m3u', '🎬 Cine y Películas', 'INT'),
    ('https://iptv-org.github.io/iptv/categories/animation.m3u', '🧸 Infantil y Animación', 'INT'),
    ('https://iptv-org.github.io/iptv/categories/kids.m3u', '🧸 Infantil y Animación', 'INT'),
    ('https://iptv-org.github.io/iptv/categories/documentary.m3u', '🌿 Documentales y Cultura', 'INT'),
    ('https://iptv-org.github.io/iptv/countries/es.m3u', '🇪🇸 España', 'ES'),
    ('https://iptv-org.github.io/iptv/countries/ar.m3u', '🇦🇷 Argentina', 'AR'),
    ('https://iptv-org.github.io/iptv/countries/co.m3u', '🇨🇴 Colombia', 'CO'),
    ('https://iptv-org.github.io/iptv/countries/cl.m3u', '🇨🇱 Chile', 'CL'),
    ('https://iptv-org.github.io/iptv/countries/pe.m3u', '🇵🇪 Perú', 'PE'),
    ('https://iptv-org.github.io/iptv/languages/spa.m3u', '🌎 Internacional y Latino', 'LAT'),
]

CATEGORY_RULES = [
    (re.compile(r'deport|sport|futbol|soccer|espn|fox sport|tudn|tyc|claro sport|gol|atletis|mma|wwe|fight|ufc|red bull|f1|racing|motor', re.I), '⚽ Deportes en Vivo'),
    (re.compile(r'cine|movie|film|pelicula|cinema|hbo|star|warner|tnt|space|amc|golden|paramount|cinemax|axn|action', re.I), '🎬 Cine y Películas'),
    (re.compile(r'anime|animac|cartoon|dibujo|disney|nick|toon|baby|chavo|infantil|kids', re.I), '🧸 Infantil y Animación'),
    (re.compile(r'series|24/7|24h|simpson|dragon ball|malcolm|retro|comedy|sitcom|telenovela|drama', re.I), '📺 Series y Canales 24/7'),
    (re.compile(r'noticia|news|milenio|adn 40|n\+|foro tv|telediario|rt |france 24|dw |euronews|telesur|c5n|tn |canal 26|info', re.I), '📰 Noticias y Opinión'),
    (re.compile(r'music|musica|telehit|bandamax|htv|mtv|radio|hit|rock|pop|urbano|tropical|sonido', re.I), '🎵 Música y Conciertos'),
    (re.compile(r'documental|documentary|historia|history|discovery|nat geo|national geo|animal planet|ciencia|nature', re.I), '🌿 Documentales y Cultura'),
]

def clean_channel_name(name):
    # Remove quality brackets like (1080p), [Not 24/7], (720p), [Geo-blocked]
    name = re.sub(r'\s*\([^)]*\)', '', name)
    name = re.sub(r'\s*\[[^\]]*\]', '', name)
    name = re.sub(r'^\d{2,3}\.?\d*\s*', '', name) # Remove channel numbers like 01.1
    name = re.sub(r'^MX\s*\|\s*', '', name, flags=re.I)
    name = re.sub(r'\s+', ' ', name).strip()
    return name

def assign_category(name, raw_group, country):
    combined = f'{name} {raw_group}'
    for pattern, cat in CATEGORY_RULES:
        if pattern.search(combined):
            return cat
    
    # Geographic fallbacks
    c = (country or '').upper()
    if c == 'MX':
        return '🇲🇽 México Nacional y Abierta'
    elif c == 'ES':
        return '🇪🇸 España'
    elif c == 'AR':
        return '🇦🇷 Argentina'
    elif c == 'CO':
        return '🇨🇴 Colombia'
    elif c in ('CL', 'PE', 'EC', 'UY', 'VE', 'GT', 'CR', 'PA', 'DO', 'PR'):
        return '🌎 Internacional y Latino'
    return '🌎 Internacional y Latino'

def probe_stream(entry):
    url = entry['url']
    try:
        req = urllib.request.Request(url, headers={
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        })
        with urllib.request.urlopen(req, timeout=3.0) as res:
            if res.status in (200, 301, 302):
                head = res.read(300).decode('utf-8', 'ignore')
                if '#EXTM3U' in head or '#EXT-X-' in head or 'Content-Type' in str(res.headers) and 'mpegurl' in str(res.headers).lower():
                    return True, entry
    except Exception:
        pass
    return False, entry

def main():
    print('Starting Master TV Harvester for InútilTV...')
    t0 = time.time()

    # Load existing master channels (keep those that work!)
    existing_map = {}
    try:
        with open('/home/cesar/Escritorio/alo/tvtv/assets/channels_master.json') as f:
            existing = json.load(f)
            for c in existing:
                existing_map[c['id']] = c
        print(f'Loaded {len(existing_map)} existing channels.')
    except Exception as e:
        print(f'Error loading existing: {e}')

    candidates = []
    seen_urls = set()

    for u, def_grp, def_co in SOURCES:
        src_name = u.rsplit('/', 1)[-1]
        print(f'Fetching {src_name}...')
        try:
            req = urllib.request.Request(u, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=12) as r:
                lines = r.read().decode('utf-8', 'ignore').splitlines()
            curr = {}
            for l in lines:
                if l.startswith('#EXTINF'):
                    curr = {}
                    m_logo = re.search(r'tvg-logo=\"([^\"]+)\"', l)
                    m_grp = re.search(r'group-title=\"([^\"]+)\"', l)
                    m_co = re.search(r'tvg-country=\"([^\"]+)\"', l)
                    m_name = re.search(r',([^,]+)$', l)
                    if m_logo: curr['logo'] = m_logo.group(1).strip()
                    if m_grp: curr['group'] = m_grp.group(1).strip()
                    if m_co: curr['country'] = m_co.group(1).strip()
                    if m_name: curr['name'] = m_name.group(1).strip()
                elif l.startswith('http') and curr:
                    stream_url = l.strip()
                    if stream_url not in seen_urls:
                        seen_urls.add(stream_url)
                        raw_name = curr.get('name', 'Canal')
                        clean_name = clean_channel_name(raw_name)
                        if len(clean_name) >= 2:
                            grp = curr.get('group') or def_grp
                            co = curr.get('country') or def_co
                            final_cat = assign_category(clean_name, grp, co)
                            candidates.append({
                                'name': clean_name,
                                'url': stream_url,
                                'logo': curr.get('logo', ''),
                                'group': final_cat,
                                'country': co.upper() if co else 'MX'
                            })
                    curr = {}
        except Exception as e:
            print(f'  Failed: {e}')

    print(f'Total candidates extracted: {len(candidates)}. Probing live streams...')
    
    verified_channels = []
    # Test in batches with high concurrency
    with concurrent.futures.ThreadPoolExecutor(max_workers=60) as ex:
        results = list(ex.map(probe_stream, candidates))
    
    alive_entries = [entry for ok, entry in results if ok]
    print(f'Alive streams verified: {len(alive_entries)} ({len(alive_entries)/max(1, len(candidates))*100:.1f}%)')

    # Merge by channel name and group
    merged_by_key = {}
    for entry in alive_entries:
        key = entry['name'].lower()
        if key not in merged_by_key:
            merged_by_key[key] = {
                'id': re.sub(r'[^a-z0-9]+', '_', key).strip('_'),
                'name': entry['name'],
                'logo': entry['logo'],
                'group': entry['group'],
                'country': entry['country'],
                'nsfw': False,
                'sources': [
                    {'url': entry['url'], 'quality': '1080p Full HD', 'headers': {}}
                ]
            }
        else:
            # Add as backup source
            existing_sources = merged_by_key[key]['sources']
            if len(existing_sources) < 3 and entry['url'] not in [s['url'] for s in existing_sources]:
                existing_sources.append({
                    'url': entry['url'],
                    'quality': '720p HD Backup',
                    'headers': {}
                })
            if not merged_by_key[key]['logo'] and entry['logo']:
                merged_by_key[key]['logo'] = entry['logo']

    # Also keep existing verified channels if not already present
    for cid, c in existing_map.items():
        key = c['name'].lower()
        if key not in merged_by_key and c.get('sources'):
            merged_by_key[key] = c

    final_list = list(merged_by_key.values())
    # Sort by group order, then name
    cat_order = [
        '🇲🇽 México Nacional y Abierta',
        '⚽ Deportes en Vivo',
        '🎬 Cine y Películas',
        '📺 Series y Canales 24/7',
        '🧸 Infantil y Animación',
        '📰 Noticias y Opinión',
        '🇪🇸 España',
        '🇦🇷 Argentina',
        '🇨🇴 Colombia',
        '🌎 Internacional y Latino',
        '🎵 Música y Conciertos',
        '🌿 Documentales y Cultura',
    ]
    def sort_key(c):
        grp = c.get('group', '')
        idx = cat_order.index(grp) if grp in cat_order else 99
        return (idx, c['name'].lower())

    final_list.sort(key=sort_key)

    # Clean IDs
    seen_ids = set()
    for i, c in enumerate(final_list):
        base_id = c['id']
        unique_id = base_id
        count = 1
        while unique_id in seen_ids or not unique_id:
            unique_id = f'{base_id}_{count}'
            count += 1
        seen_ids.add(unique_id)
        c['id'] = unique_id

    # Print summary
    print(f'\n=== FINAL CATALOG: {len(final_list)} CHANNELS ===')
    grp_counts = {}
    for c in final_list:
        g = c['group']
        grp_counts[g] = grp_counts.get(g, 0) + 1
    for g, cnt in sorted(grp_counts.items(), key=lambda x: -x[1]):
        print(f'  {g}: {cnt} canales')

    # Save to disk
    out_path = '/home/cesar/Escritorio/alo/tvtv/assets/channels_master.json'
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(final_list, f, ensure_ascii=False, indent=2)

    print(f'Saved master file to {out_path} in {time.time()-t0:.1f}s')

if __name__ == '__main__':
    main()
