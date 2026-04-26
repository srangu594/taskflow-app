// NOTE: Only import what is actually used.
// useEffect and useNavigate were removed — they caused ESLint errors.
import React, { useState } from 'react';
import { BrowserRouter as Router, Routes, Route, NavLink } from 'react-router-dom';
import {
  QueryClient,
  QueryClientProvider,
  useQuery,
  useMutation,
  useQueryClient,
} from '@tanstack/react-query';
import { Toaster, toast } from 'react-hot-toast';
import axios from 'axios';

// ── API client
// REACT_APP_API_URL is injected at Docker build time (--build-arg)
// In dev (npm start): uses "proxy" in package.json → http://localhost:8000
const API = axios.create({
  baseURL: process.env.REACT_APP_API_URL || '/api',
});

const qc = new QueryClient({
  defaultOptions: { queries: { retry: 1, staleTime: 30000 } },
});

// ── API helpers
const api = {
  tasks: {
    list:   (p) => API.get('/tasks', { params: p }).then((r) => r.data),
    create: (d) => API.post('/tasks', d).then((r) => r.data),
    update: (id, d) => API.put(`/tasks/${id}`, d).then((r) => r.data),
    delete: (id) => API.delete(`/tasks/${id}`),
    stats:  () => API.get('/tasks/stats').then((r) => r.data),
  },
  users: {
    list:   () => API.get('/users').then((r) => r.data),
    create: (d) => API.post('/users', d).then((r) => r.data),
  },
  health: {
    check: () => API.get('/health').then((r) => r.data),
  },
};

// ── Colour maps
const priorityColor = { high: '#f43f5e', medium: '#f59e0b', low: '#22c55e' };
const statusColor   = { todo: '#64748b', in_progress: '#3b82f6', done: '#10b981' };
const statusLabel   = { todo: 'To Do', in_progress: 'In Progress', done: 'Done' };
const priorityLabel = { high: 'High', medium: 'Medium', low: 'Low' };

// ── Badge component
function Badge({ color, children }) {
  return (
    <span
      style={{
        background:   color + '20',
        color,
        border:       `1px solid ${color}40`,
        borderRadius: 20,
        padding:      '2px 10px',
        fontSize:     11,
        fontWeight:   600,
        whiteSpace:   'nowrap',
      }}
    >
      {children}
    </span>
  );
}

// ── Stat card component
function StatCard({ icon, label, value, color, sub }) {
  return (
    <div
      style={{
        background:    '#1e293b',
        border:        '1px solid #334155',
        borderRadius:  16,
        padding:       '22px 24px',
        position:      'relative',
        overflow:      'hidden',
      }}
    >
      <div
        style={{
          position:   'absolute',
          top: 0, right: 0,
          width: 80, height: 80,
          background: `radial-gradient(circle, ${color}18 0%, transparent 70%)`,
        }}
      />
      <div style={{ fontSize: 28, marginBottom: 8 }}>{icon}</div>
      <div style={{ fontSize: 32, fontWeight: 800, color, marginBottom: 4 }}>{value}</div>
      <div style={{ fontSize: 14, color: '#94a3b8', fontWeight: 500 }}>{label}</div>
      {sub && <div style={{ fontSize: 12, color: '#64748b', marginTop: 4 }}>{sub}</div>}
    </div>
  );
}

// ── Task card component
function TaskCard({ task, onUpdate, onDelete }) {
  const [hover, setHover] = useState(false);

  return (
    <div
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        background:    hover ? '#1e293b' : '#1a2235',
        border:        `1px solid ${hover ? '#475569' : '#334155'}`,
        borderLeft:    `3px solid ${priorityColor[task.priority]}`,
        borderRadius:  14,
        padding:       '18px 20px',
        transition:    'all .2s',
      }}
    >
      <div
        style={{
          display:        'flex',
          alignItems:     'flex-start',
          justifyContent: 'space-between',
          gap:            10,
          marginBottom:   10,
        }}
      >
        <div style={{ fontWeight: 700, fontSize: 15, color: '#e2e8f0', flex: 1 }}>
          {task.title}
        </div>
        <Badge color={priorityColor[task.priority]}>{priorityLabel[task.priority]}</Badge>
      </div>

      {task.description && (
        <p
          style={{
            fontSize:             13,
            color:                '#64748b',
            marginBottom:         12,
            lineHeight:           1.5,
            display:              '-webkit-box',
            WebkitLineClamp:      2,
            WebkitBoxOrient:      'vertical',
            overflow:             'hidden',
          }}
        >
          {task.description}
        </p>
      )}

      <div
        style={{
          display:     'flex',
          alignItems:  'center',
          gap:         8,
          flexWrap:    'wrap',
        }}
      >
        <select
          value={task.status}
          onChange={(e) => onUpdate(task.id, { status: e.target.value })}
          style={{
            background:   statusColor[task.status] + '20',
            color:        statusColor[task.status],
            border:       `1px solid ${statusColor[task.status]}40`,
            borderRadius: 20,
            padding:      '4px 10px',
            fontSize:     11,
            fontWeight:   600,
            cursor:       'pointer',
            outline:      'none',
          }}
        >
          {Object.entries(statusLabel).map(([v, l]) => (
            <option key={v} value={v} style={{ background: '#1e293b', color: '#e2e8f0' }}>
              {l}
            </option>
          ))}
        </select>

        {task.owner && (
          <span style={{ fontSize: 11, color: '#64748b' }}>@{task.owner.username}</span>
        )}

        {task.due_date && (
          <span style={{ fontSize: 11, color: '#64748b' }}>
            📅 {new Date(task.due_date).toLocaleDateString()}
          </span>
        )}

        <button
          onClick={() => onDelete(task.id)}
          style={{
            marginLeft:   'auto',
            background:   'transparent',
            border:       'none',
            color:        '#ef4444',
            cursor:       'pointer',
            fontSize:     14,
            padding:      '2px 6px',
            borderRadius: 6,
            opacity:      hover ? 1 : 0,
            transition:   'opacity .2s',
          }}
        >
          ✕
        </button>
      </div>
    </div>
  );
}

// ── New Task Modal
function NewTaskModal({ users, onClose, onSave }) {
  const [form, setForm] = useState({
    title: '', description: '', priority: 'medium',
    status: 'todo', owner_id: '', due_date: '',
  });
  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  function handleSave() {
    if (!form.title.trim())  { toast.error('Title is required');    return; }
    if (!form.owner_id)       { toast.error('Assignee is required'); return; }
    onSave({
      ...form,
      owner_id: parseInt(form.owner_id, 10),
      due_date: form.due_date || null,
    });
  }

  return (
    <div
      style={{
        position:       'fixed',
        inset:          0,
        background:     'rgba(0,0,0,.7)',
        display:        'flex',
        alignItems:     'center',
        justifyContent: 'center',
        zIndex:         1000,
        backdropFilter: 'blur(4px)',
      }}
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <div
        style={{
          background:    '#1e293b',
          border:        '1px solid #334155',
          borderRadius:  20,
          padding:       32,
          width:         '100%',
          maxWidth:      520,
          maxHeight:     '90vh',
          overflowY:     'auto',
        }}
      >
        <h2 style={{ marginBottom: 24, fontSize: 20, fontWeight: 800, color: '#f1f5f9' }}>
          ✨ New Task
        </h2>

        {/* Title */}
        <div style={{ marginBottom: 16 }}>
          <label style={labelStyle}>TITLE *</label>
          <input
            value={form.title}
            onChange={(e) => set('title', e.target.value)}
            placeholder="What needs to be done?"
            style={inputStyle}
          />
        </div>

        {/* Description */}
        <div style={{ marginBottom: 16 }}>
          <label style={labelStyle}>DESCRIPTION</label>
          <textarea
            value={form.description}
            onChange={(e) => set('description', e.target.value)}
            placeholder="Add more details..."
            rows={3}
            style={{ ...inputStyle, resize: 'vertical' }}
          />
        </div>

        {/* Priority + Status */}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
          <div>
            <label style={labelStyle}>PRIORITY</label>
            <select value={form.priority} onChange={(e) => set('priority', e.target.value)} style={selectStyle}>
              <option value="low">🟢 Low</option>
              <option value="medium">🟡 Medium</option>
              <option value="high">🔴 High</option>
            </select>
          </div>
          <div>
            <label style={labelStyle}>STATUS</label>
            <select value={form.status} onChange={(e) => set('status', e.target.value)} style={selectStyle}>
              <option value="todo">To Do</option>
              <option value="in_progress">In Progress</option>
              <option value="done">Done</option>
            </select>
          </div>
        </div>

        {/* Assign to */}
        <div style={{ marginBottom: 16 }}>
          <label style={labelStyle}>ASSIGN TO *</label>
          <select value={form.owner_id} onChange={(e) => set('owner_id', e.target.value)} style={selectStyle}>
            <option value="">Select user...</option>
            {users.map((u) => (
              <option key={u.id} value={u.id}>
                {u.full_name} (@{u.username})
              </option>
            ))}
          </select>
        </div>

        {/* Due date */}
        <div style={{ marginBottom: 24 }}>
          <label style={labelStyle}>DUE DATE</label>
          <input
            type="datetime-local"
            value={form.due_date}
            onChange={(e) => set('due_date', e.target.value)}
            style={{ ...inputStyle, colorScheme: 'dark' }}
          />
        </div>

        {/* Buttons */}
        <div style={{ display: 'flex', gap: 12 }}>
          <button onClick={onClose} style={cancelBtnStyle}>Cancel</button>
          <button onClick={handleSave} style={createBtnStyle}>✨ Create Task</button>
        </div>
      </div>
    </div>
  );
}

// Shared styles for modal
const labelStyle = {
  display: 'block', fontSize: 11, color: '#94a3b8',
  fontWeight: 600, marginBottom: 6, letterSpacing: '.5px',
};
const inputStyle = {
  width: '100%', background: '#0f172a', border: '1px solid #334155',
  borderRadius: 8, padding: '10px 13px', color: '#e2e8f0',
  fontSize: 14, outline: 'none', fontFamily: 'inherit',
};
const selectStyle = {
  ...inputStyle, cursor: 'pointer',
};
const cancelBtnStyle = {
  flex: 1, padding: '12px', background: 'transparent',
  border: '1px solid #334155', borderRadius: 12,
  color: '#94a3b8', fontSize: 14, cursor: 'pointer', fontWeight: 600,
};
const createBtnStyle = {
  flex: 2, padding: '12px',
  background: 'linear-gradient(135deg, #6366f1, #8b5cf6)',
  border: 'none', borderRadius: 12,
  color: '#fff', fontSize: 14, cursor: 'pointer', fontWeight: 700,
};

// ── Dashboard page
function Dashboard() {
  const { data: stats }  = useQuery({ queryKey: ['stats'],  queryFn: api.tasks.stats });
  const { data: tasks }  = useQuery({ queryKey: ['tasks-recent'], queryFn: () => api.tasks.list({ limit: 5 }) });
  const { data: health } = useQuery({ queryKey: ['health'], queryFn: api.health.check, refetchInterval: 30000 });

  const cards = [
    { icon: '📋', label: 'Total Tasks',   value: stats?.total        ?? '—', color: '#6366f1', sub: 'All tasks' },
    { icon: '🔄', label: 'In Progress',   value: stats?.in_progress  ?? '—', color: '#3b82f6', sub: 'Active now' },
    { icon: '✅', label: 'Completed',     value: stats?.done         ?? '—', color: '#10b981', sub: 'Finished' },
    { icon: '🔴', label: 'High Priority', value: stats?.high_priority ?? '—', color: '#f43f5e', sub: 'Needs attention' },
  ];

  return (
    <div>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 32, flexWrap: 'wrap', gap: 16 }}>
        <div>
          <h1 style={{ fontSize: 28, fontWeight: 800, color: '#f1f5f9', marginBottom: 4 }}>Dashboard</h1>
          <p style={{ color: '#64748b', fontSize: 14 }}>Welcome back — here's your overview</p>
        </div>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 8,
          background: '#1e293b',
          border: `1px solid ${health?.status === 'ok' ? '#10b98140' : '#ef444440'}`,
          borderRadius: 20, padding: '6px 16px',
          fontSize: 12, fontWeight: 600,
          color: health?.status === 'ok' ? '#10b981' : '#ef4444',
        }}>
          <span style={{ width: 7, height: 7, borderRadius: '50%', background: 'currentColor', display: 'inline-block' }} />
          API {health?.status === 'ok' ? 'Healthy' : 'Degraded'}
        </div>
      </div>

      {/* Stat cards */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))', gap: 16, marginBottom: 36 }}>
        {cards.map((c) => <StatCard key={c.label} {...c} />)}
      </div>

      {/* Recent tasks */}
      <h2 style={{ fontSize: 18, fontWeight: 700, color: '#e2e8f0', marginBottom: 16 }}>Recent Tasks</h2>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {(tasks || []).slice(0, 5).map((t) => (
          <div
            key={t.id}
            style={{
              background: '#1e293b', border: '1px solid #334155',
              borderLeft: `3px solid ${priorityColor[t.priority]}`,
              borderRadius: 12, padding: '14px 18px',
              display: 'flex', alignItems: 'center', gap: 14,
            }}
          >
            <div style={{ flex: 1, fontWeight: 600, fontSize: 14, color: '#e2e8f0' }}>{t.title}</div>
            <Badge color={statusColor[t.status]}>{statusLabel[t.status]}</Badge>
            <Badge color={priorityColor[t.priority]}>{priorityLabel[t.priority]}</Badge>
          </div>
        ))}
        {(!tasks || tasks.length === 0) && (
          <div style={{ textAlign: 'center', padding: '48px', color: '#64748b', fontSize: 14 }}>
            No tasks yet. Create your first task! 🚀
          </div>
        )}
      </div>
    </div>
  );
}

// ── Tasks page
function Tasks() {
  const qclient = useQueryClient();
  const [showModal, setShowModal] = useState(false);
  const [filter, setFilter]       = useState({ status: '', priority: '' });

  const { data: tasks = [], isLoading } = useQuery({
    queryKey: ['tasks', filter],
    queryFn:  () => api.tasks.list({
      status:   filter.status   || undefined,
      priority: filter.priority || undefined,
    }),
  });

  const { data: users = [] } = useQuery({ queryKey: ['users'], queryFn: api.users.list });

  const createMut = useMutation({
    mutationFn: api.tasks.create,
    onSuccess:  () => {
      qclient.invalidateQueries({ queryKey: ['tasks'] });
      qclient.invalidateQueries({ queryKey: ['stats'] });
      setShowModal(false);
      toast.success('Task created! ✨');
    },
    onError: () => toast.error('Failed to create task'),
  });

  const updateMut = useMutation({
    mutationFn: ([id, d]) => api.tasks.update(id, d),
    onSuccess:  () => {
      qclient.invalidateQueries({ queryKey: ['tasks'] });
      qclient.invalidateQueries({ queryKey: ['stats'] });
      toast.success('Updated!');
    },
    onError: () => toast.error('Update failed'),
  });

  const deleteMut = useMutation({
    mutationFn: api.tasks.delete,
    onSuccess:  () => {
      qclient.invalidateQueries({ queryKey: ['tasks'] });
      qclient.invalidateQueries({ queryKey: ['stats'] });
      toast.success('Deleted');
    },
    onError: () => toast.error('Delete failed'),
  });

  const FilterBtn = ({ label, value, field }) => {
    const active = filter[field] === value;
    return (
      <button
        onClick={() => setFilter((f) => ({ ...f, [field]: f[field] === value ? '' : value }))}
        style={{
          padding:      '6px 14px',
          borderRadius: 20,
          border:       `1px solid ${active ? '#6366f1' : '#334155'}`,
          background:   active ? '#6366f120' : 'transparent',
          color:        active ? '#818cf8' : '#94a3b8',
          fontSize:     12, fontWeight: 600, cursor: 'pointer', transition: 'all .2s',
        }}
      >
        {label}
      </button>
    );
  };

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 24, flexWrap: 'wrap', gap: 12 }}>
        <h1 style={{ fontSize: 26, fontWeight: 800, color: '#f1f5f9' }}>Tasks</h1>
        <button
          onClick={() => setShowModal(true)}
          style={{
            padding: '10px 22px',
            background: 'linear-gradient(135deg, #6366f1, #8b5cf6)',
            border: 'none', borderRadius: 12,
            color: '#fff', fontSize: 14, fontWeight: 700, cursor: 'pointer',
          }}
        >
          ✨ New Task
        </button>
      </div>

      <div style={{ display: 'flex', gap: 8, marginBottom: 20, flexWrap: 'wrap' }}>
        <FilterBtn label="All"         value="" field="status" />
        <FilterBtn label="To Do"       value="todo"        field="status" />
        <FilterBtn label="In Progress" value="in_progress" field="status" />
        <FilterBtn label="Done"        value="done"        field="status" />
        <span style={{ color: '#334155', margin: '0 4px' }}>|</span>
        <FilterBtn label="🔴 High"   value="high"   field="priority" />
        <FilterBtn label="🟡 Medium" value="medium" field="priority" />
        <FilterBtn label="🟢 Low"    value="low"    field="priority" />
      </div>

      {isLoading ? (
        <div style={{ textAlign: 'center', padding: 60, color: '#64748b' }}>Loading tasks...</div>
      ) : (
        <div style={{ display: 'grid', gap: 12 }}>
          {tasks.map((t) => (
            <TaskCard
              key={t.id}
              task={t}
              onUpdate={(id, d) => updateMut.mutate([id, d])}
              onDelete={(id) => deleteMut.mutate(id)}
            />
          ))}
          {tasks.length === 0 && (
            <div style={{ textAlign: 'center', padding: '60px', color: '#64748b', fontSize: 14 }}>
              No tasks match your filters.
            </div>
          )}
        </div>
      )}

      {showModal && (
        <NewTaskModal
          users={users}
          onClose={() => setShowModal(false)}
          onSave={(d) => createMut.mutate(d)}
        />
      )}
    </div>
  );
}

// ── Team page
function Team() {
  const qclient = useQueryClient();
  const { data: users = [], isLoading } = useQuery({ queryKey: ['users'], queryFn: api.users.list });
  const { data: tasks = [] }            = useQuery({ queryKey: ['tasks-all'], queryFn: () => api.tasks.list({ limit: 200 }) });

  const [showForm, setShowForm] = useState(false);
  const [form, setForm]         = useState({ email: '', username: '', full_name: '', password: '' });

  const createUser = useMutation({
    mutationFn: api.users.create,
    onSuccess: () => {
      qclient.invalidateQueries({ queryKey: ['users'] });
      setShowForm(false);
      setForm({ email: '', username: '', full_name: '', password: '' });
      toast.success('Team member added! 🎉');
    },
    onError: (e) => toast.error(e?.response?.data?.detail || 'Failed to create user'),
  });

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 28, flexWrap: 'wrap', gap: 12 }}>
        <h1 style={{ fontSize: 26, fontWeight: 800, color: '#f1f5f9' }}>Team</h1>
        <button
          onClick={() => setShowForm((v) => !v)}
          style={{
            padding: '10px 22px',
            background: showForm ? '#334155' : 'linear-gradient(135deg, #6366f1, #8b5cf6)',
            border: 'none', borderRadius: 12,
            color: '#fff', fontSize: 14, fontWeight: 700, cursor: 'pointer',
          }}
        >
          {showForm ? '✕ Cancel' : '+ Add Member'}
        </button>
      </div>

      {showForm && (
        <div style={{ background: '#1e293b', border: '1px solid #334155', borderRadius: 16, padding: 24, marginBottom: 24 }}>
          <h3 style={{ marginBottom: 18, color: '#e2e8f0', fontWeight: 700 }}>New Team Member</h3>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14, marginBottom: 14 }}>
            {[
              ['Full Name', 'full_name', 'text'],
              ['Username',  'username',  'text'],
              ['Email',     'email',     'email'],
              ['Password',  'password',  'password'],
            ].map(([l, k, t]) => (
              <div key={k}>
                <label style={labelStyle}>{l.toUpperCase()}</label>
                <input
                  type={t}
                  value={form[k]}
                  onChange={(e) => setForm((f) => ({ ...f, [k]: e.target.value }))}
                  placeholder={l}
                  style={inputStyle}
                />
              </div>
            ))}
          </div>
          <button
            onClick={() => createUser.mutate(form)}
            style={createBtnStyle}
          >
            Add Member
          </button>
        </div>
      )}

      {isLoading ? (
        <div style={{ color: '#64748b', padding: 40 }}>Loading...</div>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))', gap: 16 }}>
          {users.map((u) => {
            const userTasks = tasks.filter((t) => t.owner_id === u.id);
            const done      = userTasks.filter((t) => t.status === 'done').length;
            return (
              <div key={u.id} style={{ background: '#1e293b', border: '1px solid #334155', borderRadius: 16, padding: 22 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 14 }}>
                  <div style={{
                    width: 48, height: 48, borderRadius: '50%',
                    background: 'linear-gradient(135deg, #6366f1, #8b5cf6)',
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    fontSize: 20, fontWeight: 800, color: '#fff', flexShrink: 0,
                  }}>
                    {u.full_name.charAt(0).toUpperCase()}
                  </div>
                  <div>
                    <div style={{ fontWeight: 700, fontSize: 15, color: '#f1f5f9' }}>{u.full_name}</div>
                    <div style={{ fontSize: 12, color: '#64748b' }}>@{u.username}</div>
                  </div>
                </div>
                <div style={{ fontSize: 12, color: '#94a3b8', marginBottom: 10 }}>{u.email}</div>
                <div style={{ display: 'flex', justifyContent: 'space-between', padding: '10px 14px', background: '#0f172a', borderRadius: 10, fontSize: 13 }}>
                  <span style={{ color: '#64748b' }}>Tasks: <strong style={{ color: '#6366f1' }}>{userTasks.length}</strong></span>
                  <span style={{ color: '#64748b' }}>Done:  <strong style={{ color: '#10b981' }}>{done}</strong></span>
                  <Badge color={u.is_active ? '#10b981' : '#ef4444'}>{u.is_active ? 'Active' : 'Inactive'}</Badge>
                </div>
              </div>
            );
          })}
          {users.length === 0 && (
            <div style={{ color: '#64748b', padding: 40, gridColumn: '1/-1', textAlign: 'center' }}>
              No team members yet.
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// ── Sidebar nav items
const NAV = [
  { to: '/',      icon: '⚡', label: 'Dashboard' },
  { to: '/tasks', icon: '📋', label: 'Tasks' },
  { to: '/team',  icon: '👥', label: 'Team' },
];

function Sidebar() {
  return (
    <aside style={{
      width: 220, background: '#0b1120',
      borderRight: '1px solid #1e293b',
      display: 'flex', flexDirection: 'column',
      padding: '20px 0', flexShrink: 0, minHeight: '100vh',
    }}>
      {/* Logo */}
      <div style={{ padding: '0 20px 24px', borderBottom: '1px solid #1e293b' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{
            width: 36, height: 36, background: 'linear-gradient(135deg, #6366f1, #8b5cf6)',
            borderRadius: 10, display: 'flex', alignItems: 'center', justifyContent: 'center',
            fontSize: 18,
          }}>⚡</div>
          <div>
            <div style={{ fontWeight: 800, fontSize: 16, color: '#f1f5f9' }}>TaskFlow</div>
            <div style={{ fontSize: 10, color: '#64748b', letterSpacing: '1px', fontFamily: 'JetBrains Mono, monospace' }}>
              3-TIER APP
            </div>
          </div>
        </div>
      </div>

      {/* Nav links */}
      <nav style={{ flex: 1, padding: '16px 12px' }}>
        {NAV.map((n) => (
          <NavLink
            key={n.to}
            to={n.to}
            end={n.to === '/'}
            style={({ isActive }) => ({
              display: 'flex', alignItems: 'center', gap: 12,
              padding: '10px 14px', borderRadius: 10, marginBottom: 4,
              textDecoration: 'none', fontWeight: 600, fontSize: 14,
              transition: 'all .2s',
              background:   isActive ? '#6366f115' : 'transparent',
              color:        isActive ? '#818cf8'   : '#64748b',
              borderLeft:   isActive ? '3px solid #6366f1' : '3px solid transparent',
            })}
          >
            <span style={{ fontSize: 16 }}>{n.icon}</span>
            {n.label}
          </NavLink>
        ))}
      </nav>

      {/* Footer */}
      <div style={{ padding: '16px 20px', borderTop: '1px solid #1e293b', fontSize: 11, color: '#334155', fontFamily: 'JetBrains Mono, monospace' }}>
        v1.0.0 · AWS EKS
      </div>
    </aside>
  );
}

// ── App root
export default function App() {
  return (
    <QueryClientProvider client={qc}>
      <Router>
        <div style={{ display: 'flex', minHeight: '100vh', background: '#0f172a' }}>
          <Sidebar />
          <main style={{ flex: 1, padding: '36px 40px', overflowY: 'auto', maxHeight: '100vh' }}>
            <Routes>
              <Route path="/"      element={<Dashboard />} />
              <Route path="/tasks" element={<Tasks />} />
              <Route path="/team"  element={<Team />} />
            </Routes>
          </main>
        </div>
        <Toaster
          position="bottom-right"
          toastOptions={{
            style: {
              background:    '#1e293b',
              color:         '#e2e8f0',
              border:        '1px solid #334155',
              borderRadius:  12,
            },
          }}
        />
      </Router>
    </QueryClientProvider>
  );
}
