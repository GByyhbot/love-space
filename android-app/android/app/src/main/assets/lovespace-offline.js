(() => {
  const params = new URLSearchParams(window.location.search);
  const fields = {
    'app-version': params.get('version') || '未知',
    'network-state': params.get('network') || '无法读取网络状态',
    'connection-detail': params.get('detail') || '连接失败'
  };
  Object.entries(fields).forEach(([id, value]) => {
    const target = document.getElementById(id);
    if (target) target.textContent = value;
  });
})();
