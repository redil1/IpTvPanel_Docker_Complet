"""Add M3U sources multi-source support

Revision ID: add_m3u_sources
Revises: d0ece1074bc0
Create Date: 2025-01-09 12:00:00.000000

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'add_m3u_sources'
down_revision = 'd0ece1074bc0'
branch_labels = None
depends_on = None


def upgrade():
    # Create m3u_sources table
    op.create_table('m3u_sources',
    sa.Column('id', sa.Integer(), nullable=False),
    sa.Column('name', sa.String(length=100), nullable=False),
    sa.Column('is_active', sa.Boolean(), nullable=True),
    sa.Column('uploaded_at', sa.DateTime(), nullable=True),
    sa.Column('total_channels', sa.Integer(), nullable=True),
    sa.Column('detected_attributes', sa.Text(), nullable=True),
    sa.Column('field_mapping', sa.Text(), nullable=True),
    sa.Column('description', sa.String(length=255), nullable=True),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('name')
    )
    op.create_index(op.f('ix_m3u_sources_is_active'), 'm3u_sources', ['is_active'], unique=False)

    # Add source_id column to channels table
    op.add_column('channels', sa.Column('source_id', sa.Integer(), nullable=True))
    op.create_index(op.f('ix_channels_source_id'), 'channels', ['source_id'], unique=False)
    op.create_foreign_key('fk_channels_source_id', 'channels', 'm3u_sources', ['source_id'], ['id'])


def downgrade():
    # Remove foreign key and column from channels
    op.drop_constraint('fk_channels_source_id', 'channels', type_='foreignkey')
    op.drop_index(op.f('ix_channels_source_id'), table_name='channels')
    op.drop_column('channels', 'source_id')

    # Drop m3u_sources table
    op.drop_index(op.f('ix_m3u_sources_is_active'), table_name='m3u_sources')
    op.drop_table('m3u_sources')
